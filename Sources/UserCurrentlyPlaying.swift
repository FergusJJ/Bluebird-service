import ArgumentParser
import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOSSL
@preconcurrency import RediStack
import Supabase

struct UserCurrentlyPlayingCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ucp",
        abstract: "Update user currently playing"
    )

    @Option(help: "Redis hostname") var redisHost: String
    @Option(help: "Redis port") var redisPort: Int = 25061
    @Option(help: "Redis password") var redisPassword: String = ""

    public var spotifyRefreshURL: URL = .init(string: "https://accounts.spotify.com")!
    public var spotifySongsURL: URL = .init(string: "https://api.spotify.com")!

    func run() async throws {
        let supabase = try SupabaseClientFactory.createClient()
        let spotifyProfiles = try await Database.getRefreshTokens(client: supabase)

        let eventLoopGroup = NIOSingletons.posixEventLoopGroup
        let eventLoop = eventLoopGroup.any()

        do {
            var userTrackDetails: [String: TrackDetail?] = [:]
            await withTaskGroup(of: (String, TrackDetail?).self) { group in
                for profile in spotifyProfiles {
                    let userId = profile.Id
                    guard profile.RefreshToken != nil else {
                        print("Skipping user \(userId): no refresh token")
                        continue
                    }
                    group.addTask {
                        do {
                            print("Fetching currently playing for: \(userId)")
                            let accessToken = try await self.getAccessTokens(spotify: profile)
                            let trackDetail = try await self.fetchCurrentlyPlayingTrack(
                                accessToken: accessToken,
                                userId: userId
                            )
                            return (userId, trackDetail)
                        } catch {
                            print("Failed for user \(userId): \(error)")
                            return (userId, nil)
                        }
                    }
                }
                for await (userId, trackDetail) in group {
                    userTrackDetails[userId] = trackDetail
                }
            }

            let trackDetailsToStore = userTrackDetails
            let passwordOrNil = redisPassword.isEmpty ? nil : redisPassword
            let redisConfig = try RedisConnection.Configuration(
                hostname: redisHost,
                port: redisPort,
                password: passwordOrNil
            )
            let tlsConfig = TLSConfiguration.makeClientConfiguration()
            let sslCtx = try NIOSSLContext(configuration: tlsConfig)
            let redisTCPClient = ClientBootstrap(group: eventLoop)
                .channelOption(
                    ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1
                )
                .channelInitializer { channel in
                    do {
                        try channel.pipeline.syncOperations.addHandler(
                            NIOSSLClientHandler(
                                context: sslCtx, serverHostname: redisHost
                            )
                        )
                    } catch {
                        return eventLoop.makeFailedFuture(error)
                    }
                    return channel.pipeline.addBaseRedisHandlers()
                }

            let redisConnectionFuture = RedisConnection.make(
                configuration: redisConfig, boundEventLoop: eventLoop,
                configuredTCPClient: redisTCPClient
            )
            let redisOperations = redisConnectionFuture.flatMap {
                redisConn -> EventLoopFuture<Void> in
                print("Successfully connected to Redis!")

                var futures: [EventLoopFuture<Void>] = []

                for (userId, trackDetail) in trackDetailsToStore {
                    let future = self.storeTrackInRedisFuture(
                        userId: userId,
                        trackDetail: trackDetail,
                        redis: redisConn,
                        eventLoop: eventLoop
                    )
                    futures.append(future)
                }

                return EventLoopFuture.andAllSucceed(futures, on: eventLoop)
            }

            try await redisOperations.get()
            // both this and eventLoop.shutdownGracefully throw an error
            try await eventLoopGroup.shutdownGracefully()
        } catch {
            try await eventLoop.shutdownGracefully()
            throw error
        }
    }

    private func storeTrackInRedisFuture(
        userId: String,
        trackDetail: TrackDetail?,
        redis: RedisConnection,
        eventLoop: EventLoop
    ) -> EventLoopFuture<Void> {
        let redisKey = RedisKey("user:\(userId):currently_playing")

        guard let trackDetail = trackDetail else {
            return redis.delete([redisKey]).map { _ in
                print("Deleted Redis key for user \(userId)")
                return ()
            }
        }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let jsonData = try encoder.encode(trackDetail)
            guard let jsonString = String(data: jsonData, encoding: .utf8) else {
                print("Failed to stringify JSON for user \(userId)")
                return eventLoop.makeSucceededFuture(())
            }

            return redis.set(redisKey, to: jsonString)
                .flatMap { _ in
                    redis.expire(redisKey, after: .seconds(300))
                }
                .map { _ in
                    print("Stored currently playing for user \(userId) in Redis")
                    print("JSON: \(jsonString)")
                    return ()
                }
        } catch {
            print("Failed to encode JSON for user \(userId): \(error)")
            return eventLoop.makeSucceededFuture(())
        }
    }

    // Fetch track detail (no Redis interaction)
    private func fetchCurrentlyPlayingTrack(
        accessToken: String,
        userId: String
    ) async throws -> TrackDetail? {
        guard let url = URL(string: "https://api.spotify.com/v1/me/player/currently-playing") else {
            throw BluebirdServiceError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BluebirdServiceError.invalidHTTPResponse
        }

        if httpResponse.statusCode == 204 {
            print("User \(userId) not currently playing anything (204)")
            return nil
        } else if httpResponse.statusCode != 200 {
            print("User \(userId) not currently playing (status \(httpResponse.statusCode))")
            return nil
        }

        struct CurrentlyPlayingResponse: Codable {
            let item: SpotifyItem
            let is_playing: Bool?
            let progress_ms: Int?
        }

        let currentlyPlaying = try JSONDecoder().decode(CurrentlyPlayingResponse.self, from: data)
        let track = currentlyPlaying.item

        // Get full track metadata
        let trackResult = try await getTrackDataMulti(accessToken: accessToken, trackIDs: track.id)
        guard case let .success(response) = trackResult,
              let fullTrack = response?.tracks.first
        else {
            print("No track data found for \(track.id) for user \(userId)")
            return nil
        }

        let trackDetail = TrackDetail(from: fullTrack)
        return trackDetail
    }

    // TODO: DRY
    private func getAccessTokens(spotify: Database.Spotify) async throws -> String {
        guard let refreshToken: String = spotify.RefreshToken else {
            throw BluebirdServiceError.missingRefreshToken
        }

        var request = try createRefreshTokenRequest()

        let requestData = createRequestBody(params: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": SharedConfig.spotifyClientID,
        ])
        request.httpBody = requestData.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BluebirdServiceError.invalidHTTPResponse
        }

        switch httpResponse.statusCode {
        case 200:
            struct RefreshTokenResponse: Decodable {
                let access_token: String
                enum CodingKeys: String, CodingKey { case access_token }
            }
            let decoded = try JSONDecoder().decode(RefreshTokenResponse.self, from: data)
            return decoded.access_token
        default:
            throw BluebirdServiceError.unexpectedResponseCode(
                forRequest: "RefreshToken",
                responseCode: httpResponse.statusCode
            )
        }
    }

    private func getTrackDataMulti(accessToken: String, trackIDs: String) async throws -> Result<
        SpotifyGetTracksMultiResponse?, BluebirdServiceError
    > {
        guard !trackIDs.isEmpty else { return .success(nil) }

        let request = try createGetTrackDataMultiRequest(accessToken: accessToken, tracks: trackIDs)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BluebirdServiceError.invalidHTTPResponse
        }

        switch httpResponse.statusCode {
        case 200:
            let tracksResponse = try JSONDecoder().decode(
                SpotifyGetTracksMultiResponse.self, from: data
            )
            return .success(tracksResponse)
        default:
            let spotifyError = try? JSONDecoder().decode(SpotifyErrorResponse.self, from: data)
            return .failure(
                BluebirdServiceError.spotifyAPIError(
                    message: spotifyError?.message ?? "Unknown",
                    responseCode: spotifyError?.status ?? httpResponse.statusCode
                )
            )
        }
    }

    public func createGetTrackDataMultiRequest(accessToken: String, tracks: String) throws
        -> URLRequest
    {
        guard var components = URLComponents(url: spotifySongsURL, resolvingAgainstBaseURL: true)
        else {
            throw BluebirdServiceError.invalidURLComponents(url: spotifySongsURL)
        }
        components.path = "/v1/tracks"
        components.queryItems = [URLQueryItem(name: "ids", value: tracks)]
        guard let url = components.url else { throw BluebirdServiceError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    public func createRefreshTokenRequest() throws -> URLRequest {
        guard var components = URLComponents(url: spotifyRefreshURL, resolvingAgainstBaseURL: true)
        else {
            throw BluebirdServiceError.invalidURLComponents(url: spotifyRefreshURL)
        }
        components.path = "/api/token"
        guard let url = components.url else { throw BluebirdServiceError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(createbasicAuthHeader(), forHTTPHeaderField: "Authorization")
        return request
    }

    public func createbasicAuthHeader() -> String {
        let auth = "\(SharedConfig.spotifyClientID):\(SharedConfig.spotifyClientSecret)"
        let encodedAuth = Data(auth.utf8).base64EncodedString()
        return "Basic \(encodedAuth)"
    }

    public func createRequestBody(params: [String: Any]) -> String {
        return params.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
    }
}
