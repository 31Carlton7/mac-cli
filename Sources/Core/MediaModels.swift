import Foundation

public struct TrackItem: Codable, Equatable, HumanRenderable {
    public let id: String          // Music persistent ID
    public let name: String
    public let artist: String
    public let album: String
    public let durationSeconds: Int
    public let rating: Int         // 0–5 stars (store maps from 0–100)
    public let playlist: String?   // context, omitted when n/a

    public init(id: String, name: String, artist: String, album: String,
                durationSeconds: Int, rating: Int, playlist: String?) {
        self.id = id
        self.name = name
        self.artist = artist
        self.album = album
        self.durationSeconds = durationSeconds
        self.rating = rating
        self.playlist = playlist
    }

    public var humanLine: String { "\(id)  \(name)  \(artist)  \(album)" }
}

public struct PlaylistInfo: Codable, Equatable, HumanRenderable {
    public let id: String
    public let name: String
    public let trackCount: Int
    public let kind: String        // "user" | "system"

    public init(id: String, name: String, trackCount: Int, kind: String) {
        self.id = id
        self.name = name
        self.trackCount = trackCount
        self.kind = kind
    }

    public var humanLine: String { "\(id)  \(name)  \(trackCount) tracks  [\(kind)]" }
}

public struct PlayerState: Codable, Equatable, HumanRenderable {
    public let state: String       // "playing" | "paused" | "stopped"
    public let volume: Int
    public let track: TrackItem?   // omitted when stopped/no track
    public let positionSeconds: Int?

    public init(state: String, volume: Int, track: TrackItem?, positionSeconds: Int?) {
        self.state = state
        self.volume = volume
        self.track = track
        self.positionSeconds = positionSeconds
    }

    public var humanLine: String {
        let t = track.map { "  \($0.name) — \($0.artist)" } ?? ""
        return "\(state)  vol \(volume)\(t)"
    }
}

public struct TVItem: Codable, Equatable, HumanRenderable {
    public let id: String
    public let name: String
    public let kind: String        // "movie" | "episode" | "other"
    public let show: String?
    public let seasonNumber: Int?
    public let episodeNumber: Int?

    public init(id: String, name: String, kind: String, show: String?,
                seasonNumber: Int?, episodeNumber: Int?) {
        self.id = id
        self.name = name
        self.kind = kind
        self.show = show
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
    }

    public var humanLine: String {
        let ctx = show.map { "  [\($0)]" } ?? ""
        return "\(id)  \(name)\(ctx)  (\(kind))"
    }
}

public struct ShortcutInfo: Codable, Equatable, HumanRenderable {
    public let id: String
    public let name: String
    public let folder: String?

    public init(id: String, name: String, folder: String?) {
        self.id = id
        self.name = name
        self.folder = folder
    }

    public var humanLine: String { folder.map { "\(id)  \(name)  [\($0)]" } ?? "\(id)  \(name)" }
}
