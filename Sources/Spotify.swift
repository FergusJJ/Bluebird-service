import Foundation

struct SpotifyImage: Decodable {
    let url: String
    let height: Int
    let width: Int
}

struct SpotifyArtist: Decodable {
    let name: String
}

struct SpotifyAlbum: Decodable {
    let images: [SpotifyImage]
    let name: String
}

struct SpotifyExternalURLs: Decodable {
    let spotify: String
}

struct SpotifyItem: Decodable {
    let name: String
    let artists: [SpotifyArtist]
    let album: SpotifyAlbum
    let type: String
    let id: String
    let durationMs: Int
    let externalUrls: SpotifyExternalURLs
    let uri: String

    enum CodingKeys: String, CodingKey {
        case name, artists, album, type, id, uri
        case durationMs = "duration_ms"
        case externalUrls = "external_urls"
    }
}

struct SpotifyCurrentlyPlayingResponse: Decodable {
    let item: SpotifyItem?
    let currentlyPlayingType: String
    let isPlaying: Bool

    enum CodingKeys: String, CodingKey {
        case item
        case currentlyPlayingType = "currently_playing_type"
        case isPlaying = "is_playing"
    }
}

struct TrackIDPlayedAt: Decodable {
    let trackIDs: [String]
    let playedAt: [Int]
}

struct SpotifyRecentlyPlayedItem: Decodable {
    let track: SpotifyItem
    let playedAt: String

    enum CodingKeys: String, CodingKey {
        case track
        case playedAt = "played_at"
    }
}

struct SpotifyRecentlyPlayedResponse: Decodable {
    let items: [SpotifyRecentlyPlayedItem]
}

struct SpotifyGetTracksMultiResponse: Decodable {
    let tracks: [SpotifyItem]
}

struct SpotifyErrorResponse: Decodable {
    let status: Int
    let message: String
}

// MARK: - Usage Example

/*
 // Decoding example:
 let jsonData = // your JSON data from HTTP response
 do {
     let decoder = JSONDecoder()
     let recentlyPlayed = try decoder.decode(SpotifyRecentlyPlayedResponse.self, from: jsonData)
     // Use the decoded data
     for item in recentlyPlayed.items {
         print("Track: \(item.track.name) by \(item.track.artists.first?.name ?? "Unknown")")
         print("Played at: \(item.playedAt)")
     }
 } catch {
     print("Decoding error: \(error)")
 }
 */
