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
        let artists_inserted: Int
        let tracks_inserted: Int
        let links_inserted: Int
        let plays_inserted: Int
        let message: String?
    }

    struct Track: Encodable {
        let id: String
        let name: String
        let artists: [Artist]
        let album_name: String
        let duration_ms: Int
        let album_cover_url: String?
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

    static func getExistingArtistIDs(client: SupabaseClient, artists: [String]) async throws
        -> [String]
    {
        struct Response: Decodable {
            let id: String
        }
        let rows: [Response] =
            try await client
                .from("artists")
                .select("id")
                .in("id", values: artists)
                .execute()
                .value
        let existingIDs = Set(rows.map { $0.id })
        return artists.filter { !existingIDs.contains($0) }
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
        unseenArtistsData: [Artist],
        userID: String,
        currentFetchTs: Date
    ) async throws {
        guard !userPlaysData.isEmpty || !unseenTracksData.isEmpty || !unseenArtistsData.isEmpty
        else {
            print("No new data to insert")
            return
        }

        let userPlaysJSON = userPlaysData.map {
            ["user_id": $0.user_id, "track_id": $0.track_id, "played_at": $0.played_at]
        }

        let unseenArtistsJSON = unseenArtistsData.map { artist in
            [
                "id": artist.id,
                "name": artist.name,
                "image_url": artist.image_url,
                "genres": artist.genres,
            ] as [String: Any]
        }

        let unseenTracksJSON = unseenTracksData.map { track in
            let artistsPayload = track.artists.map { ["id": $0.id, "name": $0.name] }
            return [
                "id": track.id,
                "name": track.name,
                "artists": artistsPayload,
                "album_name": track.album_name,
                "duration_ms": track.duration_ms,
                "album_cover_url": track.album_cover_url ?? "",
                "spotify_url": track.spotify_url ?? "",
            ] as [String: Any]
        }

        // Encode all data to JSON strings
        let userPlaysJSONString = try encodeToJSONString(userPlaysJSON)
        let tracksJSONString = try encodeToJSONString(unseenTracksJSON)
        let artistsJSONString = try encodeToJSONString(unseenArtistsJSON)

        let dateFormatter = ISO8601DateFormatter()
        let response: BulkInsertResponse =
            try await client
                .rpc(
                    "insert_user_song_plays_with_tracks",
                    params: [
                        "user_plays_data": userPlaysJSONString,
                        "unseen_tracks_data": tracksJSONString,
                        "unseen_artists_data": artistsJSONString,
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
            "Successfully inserted artists: \(response.artists_inserted), tracks: \(response.tracks_inserted), links: \(response.links_inserted), plays: \(response.plays_inserted)"
        )
    }

    private static func encodeToJSONString(_ value: Any) throws -> String {
        let jsonData = try JSONSerialization.data(withJSONObject: value, options: [])
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw DatabaseError.unknownError(message: "Failed to encode JSON to string")
        }
        return jsonString
    }
}
