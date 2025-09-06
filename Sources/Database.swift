import Foundation
import Supabase

enum DatabaseError: LocalizedError {
    case transactionFailed(errorDescription: String)
    case unknownError(message: String)
    case encodingFailed(error: Error)
    var errorDescription: String? {
        switch self {
        case let .transactionFailed(errorDescription):
            return "Database transaction failed: \(errorDescription)"
        case let .unknownError(message):
            return "An unknown error occurred: \(message)"
        case let .encodingFailed(error):
            return "Failed to encode data to JSON: \(error.localizedDescription)"
        }
    }
}

enum Database {
    struct Spotify: Codable {
        let Id: String
        let SpotifyUID: String?
        let RefreshToken: String?
        let TokenExpiry: String
        private enum CodingKeys: String, CodingKey {
            case Id = "id", SpotifyUID = "spotify_user_id", RefreshToken = "refresh_token",
                 TokenExpiry = "token_expiry"
        }
    }

    struct BulkInsertResponse: Decodable, CustomStringConvertible {
        let status: String
        let error: String?
        let artistsInserted: Int
        let albumsInserted: Int
        let tracksInserted: Int
        let linksInserted: Int
        let playsInserted: Int

        private enum CodingKeys: String, CodingKey {
            case status, error
            case artistsInserted = "artists_inserted"
            case albumsInserted = "albums_inserted"
            case tracksInserted = "tracks_inserted"
            case linksInserted = "links_inserted"
            case playsInserted = "plays_inserted"
        }

        var description: String {
            "artists: \(artistsInserted), albums: \(albumsInserted), tracks: \(tracksInserted), links: \(linksInserted), plays: \(playsInserted)"
        }
    }

    struct Track: Encodable {
        let id: String
        let name: String
        let artists: [Artist]
        let album_id: String
        let duration_ms: Int
        let spotify_url: String?
        let added_at: Date?
        let last_updated_at: Date?
    }

    struct Artist: Encodable {
        let id: String
        let name: String
        let image_url: String
        let genres: [String]
    }

    struct Album: Encodable {
        let id: String
        let artist_ids: [String] // only used for linking
        let name: String
        let image_url: String
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

    static func insertUserSongPlays(
        client: SupabaseClient,
        userPlaysData: [UserSongPlay],
        unseenTracksData: [Track],
        unseenArtistsData: [Artist],
        unseenAlbumsData: [Album],
        userID: String,
        currentFetchTs: Date
    ) async throws {
        guard
            !userPlaysData.isEmpty || !unseenTracksData.isEmpty || !unseenArtistsData.isEmpty
            || !unseenAlbumsData.isEmpty
        else {
            print("No new data to insert for user \(userID)")
            try await updateUserLastFetch(client: client, userID: userID, timestamp: currentFetchTs)
            return
        }

        let encoder = JSONEncoder()
        let userPlaysJSON = try encoder.encode(userPlaysData)
        let tracksJSON = try encoder.encode(unseenTracksData)
        let artistsJSON = try encoder.encode(unseenArtistsData)
        let albumsJSON = try encoder.encode(unseenAlbumsData)

        let dateFormatter = ISO8601DateFormatter()

        struct RpcParams: Encodable {
            let user_plays_data: String
            let unseen_tracks_data: String
            let unseen_artists_data: String
            let unseen_albums_data: String
            let user_id: String
            let current_fetch_ts: String
        }

        let params = RpcParams(
            user_plays_data: String(data: userPlaysJSON, encoding: .utf8)!,
            unseen_tracks_data: String(data: tracksJSON, encoding: .utf8)!,
            unseen_artists_data: String(data: artistsJSON, encoding: .utf8)!,
            unseen_albums_data: String(data: albumsJSON, encoding: .utf8)!,
            user_id: userID,
            current_fetch_ts: dateFormatter.string(from: currentFetchTs)
        )

        let response: BulkInsertResponse =
            try await client
                .rpc("insert_user_song_plays_with_tracks", params: params)
                .execute()
                .value

        if response.status == "error" {
            let err = response.error ?? "rpc failed: insert_user_song_plays_with_tracks"
            throw DatabaseError.transactionFailed(errorDescription: err)
        }

        print("Successfully inserted for user \(userID): \(response.description)")
    }

    private static func updateUserLastFetch(client: SupabaseClient, userID: String, timestamp: Date)
        async throws
    {
        try await client
            .from("spotify")
            .update(["plays_last_fetched": timestamp])
            .eq("id", value: userID)
            .execute()
    }
}
