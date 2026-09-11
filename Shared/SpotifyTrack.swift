import Foundation

struct SpotifyTrack: Decodable, Sendable {
    let id: String?
    let duration_ms: Int
    let name: String
    let artists: [Artist]
    let external_urls: Links
    let album: Album?
    struct Album: Decodable, Sendable {
        let images: [Artwork]
        struct Artwork: Decodable, Sendable { let url: URL }
    }
    var artworkURL: URL? { album?.images.first?.url }
    var smallArtworkURL: URL? { album?.images.last?.url }
    struct Artist: Decodable, Sendable { let name: String }
    struct Links: Decodable, Sendable { let spotify: URL? }
}
