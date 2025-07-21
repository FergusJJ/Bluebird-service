import Foundation
import Supabase

enum DatabaseError: LocalizedError {
    case transactionFailed(errorDescription: String)
    case unknownError(message: String)
    var errorDescription: String? {
        switch self {
        case let .transactionFailed(errorDescription):
            return "Database transaction failed: \(errorDescription)"
        case let .unknownError(message):
            return "An unknown error occurred: \(message)"
        }
    }
}

enum Database {
    struct Spotify: Decodable {
        let Id: String // id  - UUID
        let SpotifyUID: String? // spotify_user_id
        let RefreshToken: String? // refresh_token
        let TokenExpiry: String // token_expiry
        private enum CodingKeys: String, CodingKey {
            case Id = "id"
            case SpotifyUID = "spotify_user_id"
            case RefreshToken = "refresh_token"
            case TokenExpiry = "token_expiry"
        }
    }

    struct BulkInsertResponse: Decodable {
        let status: String
        let error: String?
        let tracks_inserted: Int
        let plays_inserted: Int
        let message: String?
    }

    struct Track: Encodable {
        let id: String
        let name: String
        let artist_name: String
        let album_name: String
        let duration_ms: Int
        let album_cover_url: String?
        let spotify_url: String?
        let added_at: Date?
        let last_updated_at: Date?
    }

    struct UserSongPlay: Encodable {
        let play_id: String?
        let user_id: String
        let track_id: String
        let played_at: String
    }

    static func getRefreshTokens(client: SupabaseClient) async throws -> [Spotify] {
        let spotifyProfiles: [Spotify] =
            try await client
                .from("spotify").select().execute().value
        return spotifyProfiles
    }

    static func getLastPlayedTimestamp(
        client: SupabaseClient,
        clientID: String
    ) async throws -> Int? {
        struct Response: Decodable {
            let plays_last_fetched: Date?
        }

        let rows: [Response] =
            try await client
                .from("spotify")
                .select("plays_last_fetched")
                .eq("id", value: clientID)
                .limit(1)
                .execute()
                .value

        return rows.first?.plays_last_fetched.map { Int($0.timeIntervalSince1970 * 1000) }
    }

    static func getExistingTrackIDs(client: SupabaseClient, tracks: [String]) async throws
        -> [String]
    {
        struct Response: Decodable {
            let id: String
        }
        let rows: [Response] =
            try await client
                .from("tracks")
                .select("id")
                .in("id", values: tracks)
                .execute()
                .value
        let existingIDs = Set(rows.map { $0.id })
        return tracks.filter { !existingIDs.contains($0) }
    }

    static func insertUserSongPlays(
        client: SupabaseClient,
        userPlaysData: [UserSongPlay],
        unseenTracksData: [Track],
        userID: String,
        currentFetchTs: Date
    ) async throws {
        guard !userPlaysData.isEmpty else {
            print("No new user song plays to insert")
            return
        }

        let userPlaysJSON = userPlaysData.map { play in
            [
                "user_id": play.user_id,
                "track_id": play.track_id,
                "played_at": play.played_at,
            ]
        }

        let tracksJSON = unseenTracksData.map { track in
            let album_cover_url = track.album_cover_url ?? ""
            let spotify_url = track.spotify_url ?? ""
            return [
                "id": track.id,
                "name": track.name,
                "artist_name": track.artist_name,
                "album_name": track.album_name,
                "duration_ms": track.duration_ms,
                "album_cover_url": album_cover_url,
                "spotify_url": spotify_url,
            ]
        }

        let userPlaysJSONData = try JSONEncoder().encode(userPlaysJSON)
        let userPlaysJSONString = String(data: userPlaysJSONData, encoding: .utf8)!

        let tracksJSONData = try JSONSerialization.data(withJSONObject: tracksJSON, options: [])
        let tracksJSONString = String(data: tracksJSONData, encoding: .utf8)!

        let dateFormatter = ISO8601DateFormatter()
        let response: BulkInsertResponse =
            try await client
                .rpc(
                    "insert_user_song_plays_with_tracks",
                    params: [
                        "user_plays_data": userPlaysJSONString,
                        "unseen_tracks_data": tracksJSONString,
                        "user_id": userID,
                        "current_fetch_ts": dateFormatter.string(from: currentFetchTs),
                    ]
                )
                .execute()
                .value

        if response.status == "error" {
            let err = response.error ?? "rpc failed: insert_user_song_plays_with_tracks"
            throw DatabaseError.transactionFailed(errorDescription: err)
        }

        print(
            "Successfully inserted \(response.tracks_inserted) tracks and \(response.plays_inserted) plays"
        )
    }
}
