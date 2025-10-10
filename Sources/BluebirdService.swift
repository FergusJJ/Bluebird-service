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

enum SharedConfig {
    static let supabaseKey = ProcessInfo.processInfo.environment["SUPABASE_SERVICE_ROLE"] ?? ""
    static let supabaseURL = ProcessInfo.processInfo.environment["SUPABASE_URL"] ?? ""
    static let spotifyClientSecret =
        ProcessInfo.processInfo.environment["SPOTIFY_CLIENT_SECRET"] ?? ""
    static let spotifyClientID = ProcessInfo.processInfo.environment["SPOTIFY_CLIENT_ID"] ?? ""
}

enum SupabaseClientFactory {
    static func createClient() throws -> SupabaseClient {
        guard !SharedConfig.supabaseKey.isEmpty else {
            print("Error: SUPABASE_SERVICE_ROLE environment variable not set or empty.")
            throw ExitCode.failure
        }

        guard !SharedConfig.supabaseURL.isEmpty else {
            print("Error: SUPABASE_URL environment variable not set or empty.")
            throw ExitCode.failure
        }

        guard let actualSupabaseURL = URL(string: SharedConfig.supabaseURL) else {
            print("Error: Invalid SUPABASE_URL format.")
            throw ExitCode.failure
        }

        return SupabaseClient(
            supabaseURL: actualSupabaseURL,
            supabaseKey: SharedConfig.supabaseKey,
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
    }
}

@main
struct BluebirdService: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Bluebird Service for Spotify integration",
        subcommands: [
            UserTracksCommand.self, UserCountsCommand.self, UserCurrentlyPlayingCommand.self,
        ],
        defaultSubcommand: UserTracksCommand.self
    )

    static func prettyPrint<T: Encodable>(_ object: T, label: String) {
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
}
