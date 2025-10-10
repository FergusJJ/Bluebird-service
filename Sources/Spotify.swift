import Foundation

struct SpotifyImage: Decodable, Encodable, Hashable {
    let url: String
    let height: Int?
    let width: Int?
}

struct SpotifyArtist: Decodable, Encodable, Hashable {
    let id: String
    let name: String
    let images: [SpotifyImage]?
    let genres: [String]?

    static func == (lhs: SpotifyArtist, rhs: SpotifyArtist) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct SpotifyAlbum: Decodable, Encodable, Hashable {
    let id: String
    let name: String
    let images: [SpotifyImage]
    let artists: [SpotifyArtist]

    static func == (lhs: SpotifyAlbum, rhs: SpotifyAlbum) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct SpotifyExternalURLs: Decodable, Encodable, Hashable {
    let spotify: String
}

struct SpotifyItem: Decodable, Encodable, Hashable {
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

    static func == (lhs: SpotifyItem, rhs: SpotifyItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
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

struct SpotifyGetArtistsMultiResponse: Decodable {
    let artists: [SpotifyArtist]
}

struct SpotifyGetTracksMultiResponse: Decodable {
    let tracks: [SpotifyItem]
}

struct SpotifyErrorContainer: Decodable {
    let error: SpotifyErrorResponse
}

struct SpotifyErrorResponse: Decodable {
    let status: Int
    let message: String
}

struct TrackDetailArtist: Encodable, Decodable, Identifiable {
    let id: String
    let image_url: String
    let name: String
}

struct TrackDetail: Encodable, Decodable, Identifiable, Hashable {
    let track_id: String
    let album_id: String
    let name: String
    let artists: [TrackDetailArtist]
    let duration_ms: Int
    let spotify_url: String
    let album_name: String
    let album_image_url: String
    let listened_at: Int?

    var id: String {
        if let ts = listened_at {
            return "\(track_id)-\(ts)"
        } else {
            return "\(track_id)-\(UUID().uuidString)"
        }
    }

    static func == (lhs: TrackDetail, rhs: TrackDetail) -> Bool {
        return lhs.track_id == rhs.track_id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    init(from spotifyItem: SpotifyItem, listenedAt: Int? = nil) {
        track_id = spotifyItem.id
        album_id = spotifyItem.album.id
        name = spotifyItem.name
        artists = spotifyItem.artists.map { artist in
            TrackDetailArtist(
                id: artist.id,
                image_url: artist.images?.first?.url ?? "",
                name: artist.name
            )
        }
        duration_ms = spotifyItem.durationMs
        spotify_url = spotifyItem.externalUrls.spotify
        album_name = spotifyItem.album.name
        album_image_url = spotifyItem.album.images.first?.url ?? ""
        listened_at = listenedAt
    }
}
