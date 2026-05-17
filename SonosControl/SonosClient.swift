import Foundation

/// SOAP client for talking to a single Sonos player over the local UPnP API.
///
/// Sonos players expose UPnP services on port 1400. All actions are SOAP POSTs
/// to a per-service control URL. We model just the actions this app needs.
struct SonosClient {
    let device: SonosDevice

    // MARK: - Service definitions

    private enum Service {
        case avTransport
        case renderingControl
        case groupRenderingControl
        case contentDirectory
        case zoneGroupTopology

        var controlPath: String {
            switch self {
            case .avTransport:           return "/MediaRenderer/AVTransport/Control"
            case .renderingControl:      return "/MediaRenderer/RenderingControl/Control"
            case .groupRenderingControl: return "/MediaRenderer/GroupRenderingControl/Control"
            case .contentDirectory:      return "/MediaServer/ContentDirectory/Control"
            case .zoneGroupTopology:     return "/ZoneGroupTopology/Control"
            }
        }

        var urn: String {
            switch self {
            case .avTransport:           return "urn:schemas-upnp-org:service:AVTransport:1"
            case .renderingControl:      return "urn:schemas-upnp-org:service:RenderingControl:1"
            case .groupRenderingControl: return "urn:schemas-upnp-org:service:GroupRenderingControl:1"
            case .contentDirectory:      return "urn:schemas-upnp-org:service:ContentDirectory:1"
            case .zoneGroupTopology:     return "urn:schemas-upnp-org:service:ZoneGroupTopology:1"
            }
        }
    }

    // MARK: - Transport (AVTransport)

    func play() async throws {
        try await soap(.avTransport, action: "Play",
                       args: [("InstanceID", "0"), ("Speed", "1")])
    }

    func pause() async throws {
        try await soap(.avTransport, action: "Pause", args: [("InstanceID", "0")])
    }

    func next() async throws {
        try await soap(.avTransport, action: "Next", args: [("InstanceID", "0")])
    }

    func previous() async throws {
        try await soap(.avTransport, action: "Previous", args: [("InstanceID", "0")])
    }

    func getTransportInfo() async throws -> TransportState {
        let body = try await soap(.avTransport, action: "GetTransportInfo",
                                  args: [("InstanceID", "0")])
        let state = extractFirst(body, tag: "CurrentTransportState") ?? "STOPPED"
        return TransportState(raw: state)
    }

    func getPositionInfo() async throws -> NowPlaying {
        let body = try await soap(.avTransport, action: "GetPositionInfo",
                                  args: [("InstanceID", "0")])
        let mediaBody = try await soap(.avTransport, action: "GetMediaInfo",
                                       args: [("InstanceID", "0")])

        let trackURI = extractFirst(body, tag: "TrackURI") ?? ""
        let relTime = parseDuration(extractFirst(body, tag: "RelTime") ?? "0")
        let trackDuration = parseDuration(extractFirst(body, tag: "TrackDuration") ?? "0")
        let trackMetaRaw = extractFirst(body, tag: "TrackMetaData") ?? ""
        let trackMeta = decodeXMLEntities(trackMetaRaw)

        // Try transport state in parallel — but we want it inline for the snapshot.
        let state = try await getTransportInfo()

        // For radio streams, AVTransportURIMetaData has the station name.
        let avMetaRaw = extractFirst(mediaBody, tag: "CurrentURIMetaData") ?? ""
        let avMeta = decodeXMLEntities(avMetaRaw)

        // Inner DIDL values can contain a second layer of XML entities
        // (e.g. "Mumford &amp; Sons"). Decode once more after extraction.
        let title = decodeXMLEntities(extractFirst(trackMeta, tag: "dc:title") ?? "")
        var artist = decodeXMLEntities(
            extractFirst(trackMeta, tag: "dc:creator")
            ?? extractFirst(trackMeta, tag: "r:albumArtist")
            ?? ""
        )
        let album = decodeXMLEntities(extractFirst(trackMeta, tag: "upnp:album") ?? "")
        let rawStreamContent = decodeXMLEntities(extractFirst(trackMeta, tag: "r:streamContent") ?? "")
        let artRelative = decodeXMLEntities(extractFirst(trackMeta, tag: "upnp:albumArtURI") ?? "")

        // For radio, the "track title" is often empty or just the station; the
        // station name comes from the AV URI metadata.
        var resolvedTitle = title
        if resolvedTitle.isEmpty {
            resolvedTitle = decodeXMLEntities(extractFirst(avMeta, tag: "dc:title") ?? "")
        }

        // SiriusXM sends streamContent in a custom pipe-delimited format:
        // "TYPE=SNG|TITLE Cross You|ARTIST Whoever|ALBUM Foo"
        // Pull the real title + artist out of it.
        let streamContent: String
        if rawStreamContent.contains("|") && rawStreamContent.contains("TITLE") {
            let parsed = parseSiriusXMStreamContent(rawStreamContent)
            streamContent = parsed.title
            if artist.isEmpty { artist = parsed.artist }
        } else {
            streamContent = rawStreamContent
        }

        let artURL: URL? = {
            guard !artRelative.isEmpty else { return nil }
            if artRelative.hasPrefix("http") {
                return URL(string: artRelative)
            }
            return URL(string: artRelative, relativeTo: device.baseURL)?.absoluteURL
        }()

        return NowPlaying(
            transportState: state,
            title: resolvedTitle,
            artist: artist,
            album: album,
            albumArtURL: artURL,
            streamContent: streamContent,
            trackURI: trackURI,
            position: relTime,
            duration: trackDuration
        )
    }

    // MARK: - Volume (RenderingControl + GroupRenderingControl)

    func getVolume() async throws -> Int {
        let body = try await soap(.renderingControl, action: "GetVolume",
                                  args: [("InstanceID", "0"), ("Channel", "Master")])
        return Int(extractFirst(body, tag: "CurrentVolume") ?? "0") ?? 0
    }

    func setVolume(_ value: Int) async throws {
        let clamped = max(0, min(100, value))
        try await soap(.renderingControl, action: "SetVolume",
                       args: [("InstanceID", "0"),
                              ("Channel", "Master"),
                              ("DesiredVolume", "\(clamped)")])
    }

    func getGroupVolume() async throws -> Int {
        let body = try await soap(.groupRenderingControl, action: "GetGroupVolume",
                                  args: [("InstanceID", "0")])
        return Int(extractFirst(body, tag: "CurrentVolume") ?? "0") ?? 0
    }

    func setGroupVolume(_ value: Int) async throws {
        let clamped = max(0, min(100, value))
        try await soap(.groupRenderingControl, action: "SetGroupVolume",
                       args: [("InstanceID", "0"), ("DesiredVolume", "\(clamped)")])
    }

    // MARK: - Grouping (AVTransport)

    /// Join this device's group to `coordinatorUUID`'s group (becomes a member).
    func joinGroup(coordinatorUUID: String) async throws {
        try await soap(.avTransport, action: "SetAVTransportURI",
                       args: [("InstanceID", "0"),
                              ("CurrentURI", "x-rincon:\(coordinatorUUID)"),
                              ("CurrentURIMetaData", "")])
    }

    /// Leave any group — become a standalone player.
    func leaveGroup() async throws {
        try await soap(.avTransport, action: "BecomeCoordinatorOfStandaloneGroup",
                       args: [("InstanceID", "0")])
    }

    // MARK: - Topology

    /// Fetch full zone group topology — describes all players on the household
    /// and how they're grouped right now.
    func getZoneGroupState() async throws -> String {
        let body = try await soap(.zoneGroupTopology, action: "GetZoneGroupState", args: [])
        return decodeXMLEntities(extractFirst(body, tag: "ZoneGroupState") ?? "")
    }

    // MARK: - Favorites (ContentDirectory)

    func browseFavorites() async throws -> [SonosFavorite] {
        let body = try await soap(.contentDirectory, action: "Browse",
                                  args: [("ObjectID", "FV:2"),
                                         ("BrowseFlag", "BrowseDirectChildren"),
                                         ("Filter", "*"),
                                         ("StartingIndex", "0"),
                                         ("RequestedCount", "100"),
                                         ("SortCriteria", "")])
        let resultRaw = extractFirst(body, tag: "Result") ?? ""
        let didl = decodeXMLEntities(resultRaw)
        return parseFavorites(didl)
    }

    func playFavorite(_ favorite: SonosFavorite) async throws {
        let uri = favorite.resourceURI
        // Container URIs (albums, playlists, browse-result lists) can't be
        // handed to SetAVTransportURI directly — that returns UPnP error 714.
        // They have to be loaded into the queue, then we play the queue.
        // Direct streams (radio, line-in, single tracks) DO work via
        // SetAVTransportURI.
        let isContainer = uri.hasPrefix("x-rincon-cpcontainer:")
            || uri.hasPrefix("x-rincon-playlist:")
            || uri.hasPrefix("file:")
            || uri.hasPrefix("x-sonos-spotify:") && uri.contains("flags=8232")

        if isContainer {
            try await replaceQueueWith(uri: uri, metaData: favorite.resourceMetaData)
        } else {
            try await soap(.avTransport, action: "SetAVTransportURI",
                           args: [("InstanceID", "0"),
                                  ("CurrentURI", uri),
                                  ("CurrentURIMetaData", favorite.resourceMetaData)])
        }
        try await play()
    }

    /// Clear the queue, enqueue `uri`, then point AVTransport at the queue.
    private func replaceQueueWith(uri: String, metaData: String) async throws {
        try await soap(.avTransport, action: "RemoveAllTracksFromQueue",
                       args: [("InstanceID", "0")])
        try await soap(.avTransport, action: "AddURIToQueue",
                       args: [("InstanceID", "0"),
                              ("EnqueuedURI", uri),
                              ("EnqueuedURIMetaData", metaData),
                              ("DesiredFirstTrackNumberEnqueued", "0"),
                              ("EnqueueAsNext", "1")])
        try await soap(.avTransport, action: "SetAVTransportURI",
                       args: [("InstanceID", "0"),
                              ("CurrentURI", "x-rincon-queue:\(device.uuid)#0"),
                              ("CurrentURIMetaData", "")])
    }

    // MARK: - SOAP plumbing

    @discardableResult
    private func soap(_ service: Service, action: String, args: [(String, String)]) async throws -> String {
        var request = URLRequest(url: device.baseURL.appendingPathComponent(service.controlPath))
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service.urn)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.timeoutInterval = 5

        let argsXML = args.map { "<\($0.0)>\(escapeXML($0.1))</\($0.0)>" }.joined()
        let envelope = """
        <?xml version="1.0" encoding="utf-8"?>\
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\
        <s:Body><u:\(action) xmlns:u="\(service.urn)">\(argsXML)</u:\(action)></s:Body>\
        </s:Envelope>
        """
        request.httpBody = envelope.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SonosError.invalidResponse
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        guard (200...299).contains(http.statusCode) else {
            let fault = extractFirst(body, tag: "errorCode") ?? "\(http.statusCode)"
            throw SonosError.soapFault(code: fault, body: body)
        }
        return body
    }

    // MARK: - Tiny XML helpers
    // Sonos responses are small and well-formed enough that regex/scanner-based
    // extraction is reliable and avoids the cost of full XMLParser delegates.

    private func extractFirst(_ xml: String, tag: String) -> String? {
        // Match <tag>…</tag> or <prefix:tag>…</prefix:tag>, allowing attributes.
        let pattern = "<\(NSRegularExpression.escapedPattern(for: tag))(\\s[^>]*)?>([\\s\\S]*?)</\(NSRegularExpression.escapedPattern(for: tag))>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        guard let match = regex.firstMatch(in: xml, range: range),
              let r = Range(match.range(at: 2), in: xml) else { return nil }
        return String(xml[r])
    }

    private func parseFavorites(_ didl: String) -> [SonosFavorite] {
        // Each favorite is an <item id="..."> block inside the DIDL.
        let pattern = "<item\\s+([^>]*)>([\\s\\S]*?)</item>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(didl.startIndex..<didl.endIndex, in: didl)
        var favorites: [SonosFavorite] = []
        regex.enumerateMatches(in: didl, range: range) { match, _, _ in
            guard let match = match,
                  let attrsRange = Range(match.range(at: 1), in: didl),
                  let innerRange = Range(match.range(at: 2), in: didl) else { return }
            let attrs = String(didl[attrsRange])
            let inner = String(didl[innerRange])
            let id = extractAttribute(attrs, name: "id") ?? UUID().uuidString
            let title = extractFirst(inner, tag: "dc:title") ?? "Untitled"
            let desc = extractFirst(inner, tag: "r:description") ?? ""
            let res = extractFirst(inner, tag: "res") ?? ""
            let resMeta = extractFirst(inner, tag: "r:resMD") ?? ""
            let art = extractFirst(inner, tag: "upnp:albumArtURI") ?? ""

            let artURL: URL? = {
                guard !art.isEmpty else { return nil }
                if art.hasPrefix("http") { return URL(string: art) }
                return URL(string: art, relativeTo: device.baseURL)?.absoluteURL
            }()

            favorites.append(SonosFavorite(
                id: id,
                title: title,
                description: desc,
                albumArtURL: artURL,
                resourceURI: decodeXMLEntities(res),
                resourceMetaData: decodeXMLEntities(resMeta)
            ))
        }
        return favorites
    }

    private func extractAttribute(_ attrs: String, name: String) -> String? {
        let pattern = "\(NSRegularExpression.escapedPattern(for: name))=\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(attrs.startIndex..<attrs.endIndex, in: attrs)
        guard let match = regex.firstMatch(in: attrs, range: range),
              let r = Range(match.range(at: 1), in: attrs) else { return nil }
        return String(attrs[r])
    }

    /// Parse SiriusXM's pipe-delimited stream content. Format observed:
    ///   "TYPE=SNG|TITLE Cross You|ARTIST Some Artist|ALBUM Some Album"
    /// Keys use either "KEY=VALUE" or "KEY VALUE" (space separator).
    private func parseSiriusXMStreamContent(_ s: String) -> (title: String, artist: String, album: String) {
        var title = ""
        var artist = ""
        var album = ""
        for segment in s.split(separator: "|") {
            let part = String(segment).trimmingCharacters(in: .whitespaces)
            // Try "KEY VALUE" then "KEY=VALUE"
            if let sep = part.firstIndex(where: { $0 == " " || $0 == "=" }) {
                let key = String(part[..<sep]).uppercased()
                let value = String(part[part.index(after: sep)...]).trimmingCharacters(in: .whitespaces)
                switch key {
                case "TITLE": title = value
                case "ARTIST": artist = value
                case "ALBUM": album = value
                default: break
                }
            }
        }
        return (title, artist, album)
    }

    private func parseDuration(_ s: String) -> TimeInterval {
        // HH:MM:SS or H:MM:SS
        let parts = s.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3 else { return 0 }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    private func escapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "'", with: "&apos;")
    }

    private func decodeXMLEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<")
         .replacingOccurrences(of: "&gt;", with: ">")
         .replacingOccurrences(of: "&quot;", with: "\"")
         .replacingOccurrences(of: "&apos;", with: "'")
         .replacingOccurrences(of: "&amp;", with: "&")
    }
}

enum SonosError: Error, LocalizedError {
    case invalidResponse
    case soapFault(code: String, body: String)
    case discoveryFailed(String)
    case deviceNotFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from Sonos device"
        case .soapFault(let code, _): return "Sonos error \(code)"
        case .discoveryFailed(let reason): return "Discovery failed: \(reason)"
        case .deviceNotFound(let name): return "Device not found: \(name)"
        }
    }
}
