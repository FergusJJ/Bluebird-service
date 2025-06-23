import ArgumentParser
import Foundation
import Supabase

/*

 Need to:
 - Connect to db
 - For each user:
     - get refresh token, last fetched time
     - get new access token
     - use access token to get 50 songs
     - insert songs into db
     - update the last fetched time
     - end
 -

 */

enum BluebirdServiceError: LocalizedError {
    case missingRefreshToken
    case invalidURLComponents(url: URL)
    case invalidURL
    case invalidHTTPResponse
    case decodingError(error: Error, forRequest: String)
    case unexpectedResponseCode(forRequest: String, responseCode: Int)
    case networkError(error: Error)
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

    // loading these via export $(cat .env | xargs), but could be params?
    private var supabaseKey = ProcessInfo.processInfo.environment["SUPABASE_SERVICE_ROLE"] ?? ""
    private var supabaseURL = ProcessInfo.processInfo.environment["SUPABASE_URL"] ?? ""
    private var spotifyClientSecret =
        ProcessInfo.processInfo.environment["SPOTIFY_CLIENT_SECRET"] ?? ""
    private var spotifyClientID = ProcessInfo.processInfo.environment["SPOTIFY_CLIENT_ID"] ?? ""

    private struct Spotify: Decodable {
        let Id: String // id  - UUID SQL
        let SpotifyUID: String? // spotify_user_id - test unique SQL
        let RefreshToken: String? // refresh_token - string SQL
        let TokenExpiry: String // token_expiry - now() SQL
        private enum CodingKeys: String, CodingKey {
            case Id = "id"
            case SpotifyUID = "spotify_user_id"
            case RefreshToken = "refresh_token"
            case TokenExpiry = "token_expiry"
        }
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
            return // or throw an error
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
        let spotifyProfiles: [Spotify]
        do {
            spotifyProfiles = try await getRefreshTokens(client: client)
            print("Fetched \(spotifyProfiles.count) Spotify profiles from Supabase.")
        } catch {
            print("Error fetching Spotify profiles: \(error)")
            return
        }
        // user_song_plays uses id as key so need dict of id:accessToken
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

        // once fetched profiles need to fetch all songs since last fetch for user
    }

    private func getRefreshTokens(client: SupabaseClient) async throws -> [Spotify] {
        let spotifyProfiles: [Spotify] =
            try await client
                .from("spotify").select().execute().value
        return spotifyProfiles
    }

    private func getAccessTokens(spotify: Spotify) async throws
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
