import ArgumentParser
import Foundation
import Supabase

enum BluebirdServiceError: LocalizedError {
    case missingRefreshToken
    case invalidURLComponents(url: URL)
    case invalidURL
    case invalidHTTPResponse
    case decodingError(error: Error, forRequest: String)
    case unexpectedResponseCode(forRequest: String, responseCode: Int)
    case networkError(error: Error)
    case spotifyAPIError(message: String, responseCode: Int)
    var errorDescription: String? {
        switch self {
        case .missingRefreshToken:
            return "Error: no refresh token present"
        case let .invalidURLComponents(url):
            return "Error: invalid URL components for \(url)"
        case .invalidURL:
            return "Error: invalid URL"
        case .invalidHTTPResponse:
            return "Error: invalid HTTP Response"
        case let .decodingError(error, forRequest):
            return "Decoding Error: \(error.localizedDescription) \(forRequest)"
        case let .unexpectedResponseCode(forRequest, responseCode):
            return "Error: unhandled response code for \(forRequest) (got \(responseCode))"
        case let .networkError(error):
            return "Network Error: \(error.localizedDescription)"
        case let .spotifyAPIError(message, responseCode):
            return "Spotify API Error: \(message) - \(responseCode)"
        }
    }
}

struct AppLogger: SupabaseLogger {
    func log(message: SupabaseLogMessage) {
        if message.level != SupabaseLogLevel.debug {
            print("[\(message.level)] [\(message.system)] \(message.message)")
        }
    }
}

@main
struct BluebirdService: AsyncParsableCommand {
    @Option(help: "API access key")
    public var apikey: String
    public var spotifyRefreshURL: URL = .init(string: "https://accounts.spotify.com")!
    public var spotifySongsURL: URL = .init(string: "https://api.spotify.com")!
    public var bluebirdAPIURL: URL = .init(string: "http://127.0.0.1:8080")!

    // loading these via export $(cat .env | xargs), but could be params?
    private var supabaseKey = ProcessInfo.processInfo.environment["SUPABASE_SERVICE_ROLE"] ?? ""
    private var supabaseURL = ProcessInfo.processInfo.environment["SUPABASE_URL"] ?? ""
    private var spotifyClientSecret =
        ProcessInfo.processInfo.environment["SPOTIFY_CLIENT_SECRET"] ?? ""
    private var spotifyClientID = ProcessInfo.processInfo.environment["SPOTIFY_CLIENT_ID"] ?? ""

    private struct UpdateSongHistoryResponse: Decodable {
        let Count: Int
        private enum CodingKeys: String, CodingKey {
            case Count = "count"
        }
    }

    private struct APIErrorResponse: Decodable {
        let errorCode: String
        let error: String
    }

    public func run() async throws {
        print("API KEY: \(apikey)")

        guard !supabaseKey.isEmpty else {
            print("Error: SUPABASE_SERVICE_ROLE environment variable not set or empty.")
            return
        }

        guard !supabaseURL.isEmpty else {
            print("Error: SUPABASE_URL environment variable not set or empty.")
            return
        }

        guard !spotifyClientSecret.isEmpty else {
            print("Error: SPOTIFY_CLIENT_SECRET environment variable not set or empty.")
            return
        }

        guard !spotifyClientID.isEmpty else {
            print("Error: SPOTIFY_CLIENT_ID environment variable not set or empty.")
            return
        }

        guard let actualSupabaseURL = URL(string: supabaseURL) else {
            print("Error: Invalid SUPABASE_URL format.")
            return
        }

        let client = SupabaseClient(
            supabaseURL: actualSupabaseURL,
            supabaseKey: supabaseKey,
            options: SupabaseClientOptions(
                auth: SupabaseClientOptions.AuthOptions(
                    storage: EphemeralAuthStorage(),
                    autoRefreshToken: false,
                ),
                global: SupabaseClientOptions.GlobalOptions(
                    logger: AppLogger()
                )
            )
        )
        let spotifyProfiles: [Database.Spotify]
        do {
            spotifyProfiles = try await Database.getRefreshTokens(client: client)
            print("Fetched \(spotifyProfiles.count) Spotify profiles from Supabase.")
        } catch {
            print("Error fetching Spotify profiles: \(error)")
            return
        }

        var UserIdAccessToken: [String: String?] = [:]
        await withTaskGroup(of: (String, String?).self) { group in
            for profile in spotifyProfiles {
                group.addTask {
                    do {
                        print("Fetching Access Token for: \(profile.SpotifyUID ?? "")")
                        // let accessToken = try await getAccessTokens(spotify: profile)
                        let accessToken = try await getAccessTokens(spotify: profile)
                        return (profile.Id, accessToken)
                    } catch {
                        print(error.localizedDescription)
                        return (profile.Id, nil)
                    }
                }
            }
            for await (profileId, accessToken) in group {
                UserIdAccessToken.updateValue(accessToken, forKey: profileId)
            }
        }

        await withTaskGroup(of: Void.self) { group in
            for u in UserIdAccessToken {
                let clientID = u.key
                guard let clientAccessToken = u.value else {
                    continue
                }
                group.addTask {
                    await processUserSongs(
                        client: client, clientID: clientID, clientAccessToken: clientAccessToken
                    )
                }
            }
        }
    }

    private func processUserSongs(
        client: SupabaseClient, clientID: String, clientAccessToken: String
    ) async {
        let now = Date()
        do {
            let lastPlayedMillis = try await Database.getLastPlayedTimestamp(
                client: client, clientID: clientID
            )

            /*
                 What we get from recentlyPlayed:

                 Artists: (simplifiedArtist)
                     - id
                     - name
                     NEED: genres, images
                Tracks:
                    - id
                    - name
                    - duration
                    - url
                    - album.id
                Albums:
                    - id
                    - name
                    - image

             */

            let recentlyPlayedResult = try await getRecentlyPlayedTracks(
                clientAccessToken: clientAccessToken,
                lastPlayedMillis: lastPlayedMillis ?? 0
            )

            guard case let .success(recentlyPlayedResponse) = recentlyPlayedResult,
                  !recentlyPlayedResponse.items.isEmpty
            else {
                print("No new tracks to process for user \(clientID).")
                try await Database.insertUserSongPlays(
                    client: client, userPlaysData: [], unseenTracksData: [], unseenArtistsData: [],
                    unseenAlbumsData: [], userID: clientID, currentFetchTs: now
                )
                return
            }

            // get unique entries, for insertion into respective table
            let allTracks = Set(recentlyPlayedResponse.items.map { $0.track })
            let allAlbums = Set(allTracks.map { $0.album })
            let allArtists = Set(
                allTracks.flatMap { $0.artists } + allAlbums.flatMap { $0.artists })

            let userSongPlays = prepareUserSongPlaysData(
                spotifyResponse: recentlyPlayedResponse.items, userId: clientID
            )

            var artistsToInsert: [Database.Artist] = []
            if !allArtists.isEmpty {
                let artistIds = allArtists.map { $0.id }.joined(separator: ",")
                let getArtistsResult = try await getArtistDataMulti(
                    accessToken: clientAccessToken, artistIDs: artistIds
                )
                if case let .success(getArtistsResult) = getArtistsResult,
                   !getArtistsResult.artists.isEmpty
                {
                    artistsToInsert = prepareArtistsData(spotifyResponse: getArtistsResult.artists)
                } else {
                    print("No new artists to process")
                }
            }

            let tracksToInsert = prepareTracksData(spotifyResponse: Array(allTracks))
            let albumsToInsert = prepareAlbumData(spotifyResponse: Array(allAlbums))

            prettyPrint(artistsToInsert, label: "Artists to Insert")
            prettyPrint(tracksToInsert, label: "Tracks to Insert")
            prettyPrint(albumsToInsert, label: "Albums to Insert")
            try await Database.insertUserSongPlays(
                client: client,
                userPlaysData: userSongPlays,
                unseenTracksData: tracksToInsert,
                unseenArtistsData: artistsToInsert,
                unseenAlbumsData: albumsToInsert,
                userID: clientID,
                currentFetchTs: now
            )

        } catch {
            print("Failed to process songs for user \(clientID): \(error.localizedDescription)")
            return
        }
    }

    func prettyPrint<T: Encodable>(_ object: T, label: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(object)
            if let jsonString = String(data: data, encoding: .utf8) {
                print("\n=== \(label) ===")
                print(jsonString)
            }
        } catch {
            print("Failed to encode \(label): \(error)")
        }
    }

    private func getArtistDataMulti(accessToken: String, artistIDs: String) async throws -> Result<
        SpotifyGetArtistsMultiResponse, BluebirdServiceError
    > {
        var request: URLRequest
        do {
            request =
                try createGetArtistDataMultiRequest(
                    accessToken: accessToken,
                    artists: artistIDs
                )
        } catch {
            throw error
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw BluebirdServiceError.invalidHTTPResponse
            }

            switch httpResponse.statusCode {
            case 200:
                do {
                    let spotifyGetArtistsMultiResponse = try JSONDecoder().decode(
                        SpotifyGetArtistsMultiResponse.self, from: data
                    )
                    return .success(spotifyGetArtistsMultiResponse)
                } catch {
                    throw BluebirdServiceError.decodingError(
                        error: error,
                        forRequest: "getArtistDataMulti - \(httpResponse.statusCode)"
                    )
                }
            default:
                do {
                    let spotifyErrorResponse = try JSONDecoder().decode(
                        SpotifyErrorResponse.self, from: data
                    )
                    return .failure(
                        BluebirdServiceError.spotifyAPIError(
                            message: spotifyErrorResponse.message,
                            responseCode: spotifyErrorResponse.status
                        ))
                } catch {
                    throw BluebirdServiceError.decodingError(
                        error: error,
                        forRequest: "getArtistDataMulti - \(httpResponse.statusCode)"
                    )
                }
            }
        }
    }

    private func getTrackDataMulti(accessToken: String, trackIDs: String) async throws -> Result<
        SpotifyGetTracksMultiResponse?, BluebirdServiceError
    > {
        guard !trackIDs.isEmpty else {
            return .success(nil)
        }
        var request: URLRequest
        do {
            request =
                try createGetTrackDataMultiRequest(
                    accessToken: accessToken,
                    tracks: trackIDs
                )
        } catch {
            throw error
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw BluebirdServiceError.invalidHTTPResponse
            }

            switch httpResponse.statusCode {
            case 200:
                do {
                    let spotifyGetTracksMultiResponse = try JSONDecoder().decode(
                        SpotifyGetTracksMultiResponse.self, from: data
                    )
                    return .success(spotifyGetTracksMultiResponse)
                } catch {
                    throw BluebirdServiceError.decodingError(
                        error: error,
                        forRequest: "getRecentlyPlayedTracks - \(httpResponse.statusCode)"
                    )
                }
            default:
                do {
                    let spotifyErrorResponse = try JSONDecoder().decode(
                        SpotifyErrorResponse.self, from: data
                    )
                    return .failure(
                        BluebirdServiceError.spotifyAPIError(
                            message: spotifyErrorResponse.message,
                            responseCode: spotifyErrorResponse.status
                        ))
                } catch {
                    throw BluebirdServiceError.decodingError(
                        error: error,
                        forRequest: "getRecentlyPlayedTracks - \(httpResponse.statusCode)"
                    )
                }
            }
        }
    }

    private func getAccessTokens(spotify: Database.Spotify) async throws
        -> String
    {
        guard let refreshToken: String = spotify.RefreshToken else {
            throw BluebirdServiceError.missingRefreshToken
        }
        var request: URLRequest
        do {
            request = try createRefreshTokenRequest()
        } catch {
            throw error
        }
        let requestData = createRequestBody(params: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": spotifyClientID,
        ])
        request.httpBody = requestData.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw BluebirdServiceError.invalidHTTPResponse
            }

            switch httpResponse.statusCode {
            case 200:
                struct RefreshTokenResponse: Decodable {
                    let accessToken: String
                    let tokenType: String
                    let expiresIn: Int
                    let scope: String
                    enum CodingKeys: String, CodingKey {
                        case accessToken = "access_token"
                        case tokenType = "token_type"
                        case expiresIn = "expires_in"
                        case scope
                    }
                }
                do {
                    let refreshTokenResponse = try JSONDecoder().decode(
                        RefreshTokenResponse.self, from: data
                    )
                    return refreshTokenResponse.accessToken
                } catch {
                    throw BluebirdServiceError.decodingError(
                        error: error, forRequest: "RefreshToken"
                    )
                }
            default:
                throw BluebirdServiceError.unexpectedResponseCode(
                    forRequest: "RefreshToken",
                    responseCode: httpResponse.statusCode
                )
            }
        } catch {
            if let urlError = error as? URLError {
                throw BluebirdServiceError.networkError(error: urlError)
            }
            throw error
        }
    }

    private func getRecentlyPlayedTracks(clientAccessToken: String, lastPlayedMillis: Int)
        async throws
        -> Result<SpotifyRecentlyPlayedResponse, BluebirdServiceError>
    {
        var request: URLRequest
        do {
            request = try createGetRecentlyPlayedTracksRequest(
                accessToken: clientAccessToken, after: lastPlayedMillis
            )
        } catch {
            throw error
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw BluebirdServiceError.invalidHTTPResponse
            }
            switch httpResponse.statusCode {
            case 200:
                do {
                    let refreshTokenResponse = try JSONDecoder().decode(
                        SpotifyRecentlyPlayedResponse.self, from: data
                    )
                    return .success(refreshTokenResponse)
                } catch {
                    throw BluebirdServiceError.decodingError(
                        error: error,
                        forRequest: "getRecentlyPlayedTracks - \(httpResponse.statusCode)"
                    )
                }
            default:
                do {
                    let spotifyErrorResponse = try JSONDecoder().decode(
                        SpotifyErrorResponse.self, from: data
                    )
                    return .failure(
                        BluebirdServiceError.spotifyAPIError(
                            message: spotifyErrorResponse.message,
                            responseCode: spotifyErrorResponse.status
                        ))
                } catch {
                    throw BluebirdServiceError.decodingError(
                        error: error,
                        forRequest: "getRecentlyPlayedTracks - \(httpResponse.statusCode)"
                    )
                }
            }
        }
    }

    public func createGetArtistDataMultiRequest(accessToken: String, artists: String) throws
        -> URLRequest
    {
        guard var components = URLComponents(url: spotifySongsURL, resolvingAgainstBaseURL: true)
        else {
            throw BluebirdServiceError.invalidURLComponents(url: spotifySongsURL)
        }
        let recentlyPlayedPath = "/v1/artists"
        components.path = recentlyPlayedPath
        let queryItems = [
            URLQueryItem(name: "ids", value: artists),
        ]
        components.queryItems = queryItems
        guard let url = components.url else {
            throw BluebirdServiceError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    public func createGetTrackDataMultiRequest(accessToken: String, tracks: String) throws
        -> URLRequest
    {
        guard var components = URLComponents(url: spotifySongsURL, resolvingAgainstBaseURL: true)
        else {
            throw BluebirdServiceError.invalidURLComponents(url: spotifySongsURL)
        }
        let recentlyPlayedPath = "/v1/tracks"
        components.path = recentlyPlayedPath
        let queryItems = [
            URLQueryItem(name: "ids", value: tracks),
        ]
        components.queryItems = queryItems
        guard let url = components.url else {
            throw BluebirdServiceError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    public func createGetRecentlyPlayedTracksRequest(accessToken: String, after: Int) throws
        -> URLRequest
    {
        guard var components = URLComponents(url: spotifySongsURL, resolvingAgainstBaseURL: true)
        else {
            throw BluebirdServiceError.invalidURLComponents(url: spotifySongsURL)
        }
        let recentlyPlayedPath = "/v1/me/player/recently-played"
        components.path = recentlyPlayedPath
        let queryItems = [
            URLQueryItem(name: "limit", value: "50"),
            URLQueryItem(name: "after", value: "\(after)"),
        ]
        components.queryItems = queryItems
        guard let url = components.url else {
            throw BluebirdServiceError.invalidURL
        }
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
        let refreshPath = "/api/token"
        components.path = refreshPath
        guard let url = components.url else {
            throw BluebirdServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(createbasicAuthHeader(), forHTTPHeaderField: "Authorization")
        return request
    }

    func prepareUserSongPlaysData(spotifyResponse: [SpotifyRecentlyPlayedItem], userId: String)
        -> [Database.UserSongPlay]
    {
        return spotifyResponse.map { item in
            Database.UserSongPlay(
                play_id: nil,
                user_id: userId,
                track_id: item.track.id,
                played_at: item.playedAt
            )
        }
    }

    func prepareAlbumData(spotifyResponse: [SpotifyAlbum]) -> [Database.Album] {
        return spotifyResponse.map { album in
            Database.Album(
                id: album.id,
                artist_ids: Array(album.artists.map { $0.id }),
                name: album.name,
                image_url: album.images.first?.url ?? ""
            )
        }
    }

    func prepareArtistsData(spotifyResponse: [SpotifyArtist]) -> [Database.Artist] {
        return spotifyResponse.compactMap { artist in
            Database.Artist(
                id: artist.id,
                name: artist.name,
                image_url: artist.images?.first?.url ?? "",
                genres: artist.genres ?? []
            )
        }
    }

    func prepareTracksData(spotifyResponse: [SpotifyItem]) -> [Database.Track] {
        return spotifyResponse.map { track in
            let databaseArtists = track.artists.map { artist in
                // The SQL function only needs artist IDs inside the track object.
                // dont even really need the name here
                Database.Artist(id: artist.id, name: artist.name, image_url: "", genres: [])
            }
            return Database.Track(
                id: track.id,
                name: track.name,
                artists: databaseArtists,
                album_id: track.album.id,
                duration_ms: track.durationMs,
                spotify_url: track.externalUrls.spotify,
                added_at: nil,
                last_updated_at: nil
            )
        }
    }

    public func createbasicAuthHeader() -> String {
        let auth = "\(spotifyClientID):\(spotifyClientSecret)"
        guard let authData = auth.data(using: .utf8) else {
            fatalError("Failed to create basic auth string")
        }
        let encodedAuth = authData.base64EncodedString()
        return "Basic \(encodedAuth)"
    }

    public func createRequestBody(params: [String: Any]) -> String {
        var data = [String]()
        for (key, value) in params {
            data.append(key + "=\(value)")
        }
        return data.map { String($0) }.joined(separator: "&")
    }
}
