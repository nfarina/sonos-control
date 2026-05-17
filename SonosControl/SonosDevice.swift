import Foundation

struct SonosDevice: Identifiable, Hashable {
    let uuid: String          // e.g. "RINCON_000E58XXXXXX01400"
    let host: String          // IP address
    let zoneName: String      // e.g. "Downstairs"
    let modelName: String     // e.g. "Sonos Amp"
    let modelNumber: String   // e.g. "S16"

    var id: String { uuid }
    var baseURL: URL { URL(string: "http://\(host):1400")! }
    var isPortable: Bool {
        // Move/Move 2/Roam family — battery-powered devices.
        let m = modelName.lowercased()
        return m.contains("move") || m.contains("roam")
    }
}

/// One logical zone group (a coordinator + zero or more grouped members).
struct SonosGroup: Identifiable, Hashable {
    let id: String            // group ID from topology, e.g. "RINCON_xxx:1234567890"
    let coordinatorUUID: String
    let memberUUIDs: [String]
}

/// Now-playing snapshot for a group.
struct NowPlaying: Equatable {
    var transportState: TransportState
    var title: String
    var artist: String
    var album: String
    var albumArtURL: URL?
    var streamContent: String      // station name for radio streams
    var trackURI: String           // raw URI, useful for dedup
    var position: TimeInterval
    var duration: TimeInterval

    static let empty = NowPlaying(
        transportState: .stopped,
        title: "",
        artist: "",
        album: "",
        albumArtURL: nil,
        streamContent: "",
        trackURI: "",
        position: 0,
        duration: 0
    )

    var isRadioStream: Bool { duration == 0 && !streamContent.isEmpty }

    /// Best display title: for radio, prefer the live "stream content" (which is
    /// usually the song name) over the channel name in `title`.
    var displayTitle: String {
        if isRadioStream && !streamContent.isEmpty {
            return streamContent
        }
        return title
    }

    /// Second line: artist when known.
    var displaySubtitle: String {
        artist
    }

    /// Third line: contextual — station for radio, album for tracks.
    var displayTertiary: String {
        if isRadioStream {
            // `title` for radio is the station name (from AVTransport URI
            // metadata fallback). Don't repeat it if it duplicates the song
            // title (rare edge case).
            return title == displayTitle ? "" : title
        }
        return album
    }
}

enum TransportState: String, Equatable {
    case playing = "PLAYING"
    case paused = "PAUSED_PLAYBACK"
    case stopped = "STOPPED"
    case transitioning = "TRANSITIONING"

    init(raw: String) {
        self = TransportState(rawValue: raw) ?? .stopped
    }

    var isPlaying: Bool { self == .playing || self == .transitioning }
}

/// A historical playback entry — captured when the track changes.
struct HistoryEntry: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let artist: String
    let album: String
    let albumArtURL: URL?
    let timestamp: Date
    let trackURI: String
}

/// A Sonos favorite (typically a saved radio station, playlist, or album).
struct SonosFavorite: Identifiable, Hashable {
    let id: String                // favorite item ID, e.g. "FV:2/0"
    let title: String
    let description: String       // e.g. "TuneIn Station"
    let albumArtURL: URL?
    let resourceURI: String       // URI to play
    let resourceMetaData: String  // DIDL XML to pass back to SetAVTransportURI
}
