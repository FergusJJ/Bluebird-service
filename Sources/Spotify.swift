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
