import Foundation
import SwiftUI
import Combine

/// Central state + control for the Sonos system.
///
/// Layout assumption (Nick's house):
///   • "Downstairs"   = primary zone, always the group coordinator
///   • "Back Porch"   = optional satellite (Move 2, always available)
///   • "Front Porch"  = optional satellite (Move, often off)
///
/// All volume + transport commands target the Downstairs coordinator.
/// Back/Front Porch are only ever group members of Downstairs.
@MainActor
class SonosManager: ObservableObject {

    // MARK: - Configurable zone names
    // Persisted to UserDefaults so they can be tweaked in settings later.

    /// Name of the zone that volume and transport target. If empty (first
    /// launch), the first discovered zone is auto-selected.
    @AppStorage("zone.primary") var primaryZoneName: String = ""

    /// UUIDs of zones the user has chosen to hide from the System card
    /// (comma-separated for AppStorage compatibility). Empty = show all.
    @AppStorage("zone.hiddenUUIDs") private var hiddenUUIDsRaw: String = ""

    var hiddenZoneUUIDs: Set<String> {
        get { Set(hiddenUUIDsRaw.split(separator: ",").map(String.init)) }
        set { hiddenUUIDsRaw = newValue.sorted().joined(separator: ",") }
    }

    // MARK: - Published state

    @Published private(set) var devices: [SonosDevice] = []
    @Published private(set) var groups: [SonosGroup] = []
    @Published private(set) var nowPlaying: NowPlaying = .empty
    @Published private(set) var volume: Int = 30
    @Published private(set) var history: [HistoryEntry] = []
    @Published private(set) var favorites: [SonosFavorite] = []
    @Published private(set) var isDiscovering: Bool = false
    @Published private(set) var lastError: String?

    /// True once we've successfully pulled now-playing state at least once.
    /// Used to gate the menu bar icon's play/pause indicator — before this
    /// flips we don't actually know what state the system is in.
    @Published private(set) var hasLoadedState: Bool = false

    /// Timestamp of the last successful now-playing poll. Drives the
    /// freshness indicator in the popup.
    @Published private(set) var lastPolledAt: Date?

    /// True after 3 consecutive failed polls — typically means we're off the
    /// home network or the speakers are unreachable. Drives the menu bar
    /// icon's grey "offline" state.
    @Published private(set) var isOffline: Bool = false

    var isPlaying: Bool { nowPlaying.transportState.isPlaying }

    /// The user-designated primary zone (volume/transport target). Falls back
    /// to the first discovered device if the configured name isn't found —
    /// avoids a totally-broken state when zones get renamed.
    var primary: SonosDevice? {
        if !primaryZoneName.isEmpty,
           let match = devices.first(where: { $0.zoneName.caseInsensitiveCompare(primaryZoneName) == .orderedSame }) {
            return match
        }
        return devices.first
    }

    /// All discovered zones except the primary, filtered by the user's hidden
    /// list. These are what show up as toggleable satellites in the System card.
    var satellites: [SonosDevice] {
        let hidden = hiddenZoneUUIDs
        let primaryUUID = primary?.uuid
        return devices.filter { $0.uuid != primaryUUID && !hidden.contains($0.uuid) }
            .sorted { $0.zoneName.localizedCaseInsensitiveCompare($1.zoneName) == .orderedAscending }
    }

    /// True if the given device is currently grouped with the primary.
    func isGrouped(_ device: SonosDevice?) -> Bool {
        guard let device, let primary else { return false }
        return groups.contains { group in
            group.coordinatorUUID == primary.uuid &&
            group.memberUUIDs.contains(device.uuid)
        }
    }

    // MARK: - Internals

    private var pollTask: Task<Void, Never>?
    private var errorClearTask: Task<Void, Never>?
    private var isMenuVisible = false
    private var consecutiveFailures = 0
    private let offlineThreshold = 3
    /// Fast cadence while the menu is open (so transitions feel snappy).
    private let foregroundInterval: TimeInterval = 3.0
    /// Slow cadence while the menu is closed (just keeps history fresh).
    private let backgroundInterval: TimeInterval = 10.0
    private let historyLimit = 10

    /// Set an error message that fades on its own after a few seconds. Pass
    /// `nil` to clear immediately.
    private func showError(_ message: String?) {
        self.lastError = message
        errorClearTask?.cancel()
        guard message != nil else { return }
        errorClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled {
                self?.lastError = nil
            }
        }
    }

    init() {
        loadHistory()
        Task {
            await refreshTopology()
            // Kick off the background poll loop. It runs forever at the
            // slow cadence, switching to fast when the menu is visible.
            // History capture happens inside refreshNowPlaying() so we keep
            // recording songs even with the menu closed.
            startBackgroundPolling()
        }

        // Subscribe to every hotkey action — both global (Carbon) and in-app
        // (local NSEvent monitor) bindings post the same notifications.
        let nc = NotificationCenter.default
        nc.addObserver(forName: HotkeyAction.globalPlayPause.notificationName, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.togglePlayPause() }
        }
        nc.addObserver(forName: HotkeyAction.inAppPlayPause.notificationName, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.togglePlayPause() }
        }
        nc.addObserver(forName: HotkeyAction.inAppVolumeUp.notificationName, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.setVolume(min(100, self.volume + 2))
            }
        }
        nc.addObserver(forName: HotkeyAction.inAppVolumeDown.notificationName, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.setVolume(max(0, self.volume - 2))
            }
        }
    }

    deinit {
        pollTask?.cancel()
        errorClearTask?.cancel()
    }

    // MARK: - Discovery & topology

    /// Discover Sonos devices on the LAN and load the zone topology.
    func refreshTopology() async {
        isDiscovering = true
        defer { isDiscovering = false }

        // Use any cached device first (faster than re-running SSDP every time).
        if let any = devices.first {
            if await loadTopology(via: any) { return }
        }

        // Otherwise SSDP-discover to find any one player.
        let responses = await SSDPDiscovery.discover(timeout: 2.0)
        guard let first = responses.first, let uuid = first.uuid else {
            showError("No Sonos devices found on the network")
            logWarning("No Sonos devices found via SSDP")
            return
        }

        // Seed the device list with what we know so we have something to talk to.
        let seed = SonosDevice(
            uuid: uuid,
            host: first.sourceIP,
            zoneName: "(unknown)",
            modelName: first.server,
            modelNumber: ""
        )
        _ = await loadTopology(via: seed)
    }

    @discardableResult
    private func loadTopology(via device: SonosDevice) async -> Bool {
        do {
            let xml = try await SonosClient(device: device).getZoneGroupState()
            let parsed = parseZoneGroupState(xml)
            self.devices = parsed.devices
            self.groups = parsed.groups
            showError(nil)
            // First-launch convenience: auto-pick a primary if none configured
            // yet. The user can change it in Settings.
            if primaryZoneName.isEmpty, let first = parsed.devices.first {
                primaryZoneName = first.zoneName
                logInfo("Auto-selected '\(first.zoneName)' as primary zone (first launch)")
            }
            logInfo("Topology: \(parsed.devices.count) devices, \(parsed.groups.count) groups")
            for d in parsed.devices {
                logDebug("  • \(d.zoneName) [\(d.uuid)] @ \(d.host) (\(d.modelName))")
            }
            // Pull initial state from the primary coordinator (if it exists).
            await refreshNowPlaying()
            await refreshVolume()
            // Warm the favorites cache so the popover opens populated.
            if favorites.isEmpty {
                await fetchFavorites()
            }
            return true
        } catch {
            showError(error.localizedDescription)
            logError("loadTopology via \(device.host): \(error)")
            return false
        }
    }

    // MARK: - Polling

    /// Single long-lived poll loop. Always polls now-playing (so history
    /// keeps building when the menu is closed); only polls volume when the
    /// menu is visible (no one's looking at it otherwise). Interval depends
    /// on visibility.
    private func startBackgroundPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshNowPlaying()
                if self?.isMenuVisible == true {
                    await self?.refreshVolume()
                }
                let interval = self?.isMenuVisible == true
                    ? self?.foregroundInterval ?? 3.0
                    : self?.backgroundInterval ?? 10.0
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    /// Called when the menu opens. Triggers an immediate refresh so the UI
    /// shows current state without waiting for the next tick.
    func startPolling() {
        isMenuVisible = true
        Task {
            await refreshNowPlaying()
            await refreshVolume()
        }
    }

    /// Called when the menu closes. Polling continues at the slower
    /// background cadence.
    func stopPolling() {
        isMenuVisible = false
    }

    func refreshNowPlaying() async {
        guard let coordinator = currentCoordinator() else { return }
        do {
            let np = try await SonosClient(device: coordinator).getPositionInfo()
            let previousURI = self.nowPlaying.trackURI
            self.nowPlaying = np
            self.hasLoadedState = true
            self.lastPolledAt = Date()
            self.consecutiveFailures = 0
            if self.isOffline { self.isOffline = false }
            // Only add to history if this looks like a real track:
            //   - we have an artist (rules out station-name placeholders)
            //   - title is non-empty
            //   - trackURI changed (debounces same-song re-polls)
            let looksLikeRealSong = !np.artist.isEmpty && !np.displayTitle.isEmpty
            if looksLikeRealSong && np.trackURI != previousURI {
                addToHistory(np)
            }
        } catch {
            logDebug("refreshNowPlaying: \(error)")
            consecutiveFailures += 1
            if consecutiveFailures >= offlineThreshold && !isOffline {
                isOffline = true
                logInfo("Marking system as offline after \(consecutiveFailures) failed polls")
            }
        }
    }

    func refreshVolume() async {
        guard let coordinator = currentCoordinator() else { return }
        do {
            let client = SonosClient(device: coordinator)
            // If grouped with satellites, group volume; otherwise plain volume.
            let groupedCount = currentGroup()?.memberUUIDs.count ?? 1
            let v = groupedCount > 1
                ? try await client.getGroupVolume()
                : try await client.getVolume()
            self.volume = v
        } catch {
            logDebug("refreshVolume: \(error)")
        }
    }

    // MARK: - Actions

    func togglePlayPause() async {
        guard let coordinator = currentCoordinator() else { return }
        do {
            let client = SonosClient(device: coordinator)
            if isPlaying {
                try await client.pause()
                nowPlaying.transportState = .paused
            } else {
                try await client.play()
                nowPlaying.transportState = .playing
            }
        } catch {
            showError(error.localizedDescription)
            logError("togglePlayPause: \(error)")
        }
    }

    func next() async {
        guard let coordinator = currentCoordinator() else { return }
        try? await SonosClient(device: coordinator).next()
        await refreshNowPlaying()
    }

    func previous() async {
        guard let coordinator = currentCoordinator() else { return }
        try? await SonosClient(device: coordinator).previous()
        await refreshNowPlaying()
    }

    /// Set volume on the primary zone (group volume if grouped).
    func setVolume(_ value: Int) async {
        guard let coordinator = currentCoordinator() else { return }
        self.volume = value
        do {
            let client = SonosClient(device: coordinator)
            let groupedCount = currentGroup()?.memberUUIDs.count ?? 1
            if groupedCount > 1 {
                try await client.setGroupVolume(value)
            } else {
                try await client.setVolume(value)
            }
        } catch {
            logError("setVolume(\(value)): \(error)")
        }
    }

    /// Toggle a satellite (back/front porch) in or out of the primary group.
    func toggleSatellite(_ device: SonosDevice) async {
        guard let primary, primary.uuid != device.uuid else { return }
        let isCurrentlyGrouped = isGrouped(device)
        do {
            let client = SonosClient(device: device)
            if isCurrentlyGrouped {
                try await client.leaveGroup()
                logInfo("Removed \(device.zoneName) from group")
            } else {
                try await client.joinGroup(coordinatorUUID: primary.uuid)
                logInfo("Joined \(device.zoneName) to \(primary.zoneName)")
            }
            // Topology takes a moment to settle.
            try? await Task.sleep(nanoseconds: 500_000_000)
            await refreshTopology()
        } catch {
            showError(error.localizedDescription)
            logError("toggleSatellite(\(device.zoneName)): \(error)")
        }
    }

    func fetchFavorites() async {
        guard let coordinator = currentCoordinator() else { return }
        do {
            let favs = try await SonosClient(device: coordinator).browseFavorites()
            self.favorites = favs
            logInfo("Loaded \(favs.count) favorites")
        } catch {
            logError("fetchFavorites: \(error)")
        }
    }

    func playFavorite(_ favorite: SonosFavorite) async {
        guard let coordinator = currentCoordinator() else { return }
        do {
            try await SonosClient(device: coordinator).playFavorite(favorite)
            try? await Task.sleep(nanoseconds: 400_000_000)
            await refreshNowPlaying()
        } catch {
            showError(error.localizedDescription)
            logError("playFavorite(\(favorite.title)): \(error)")
        }
    }

    func clearHistory() {
        history = []
        saveHistory()
    }

    // MARK: - Helpers

    /// Returns the device that's actually the coordinator of the primary zone's
    /// group. (Usually just the primary itself, but if some weird re-grouping
    /// happened it might differ.)
    private func currentCoordinator() -> SonosDevice? {
        guard let primary else { return nil }
        if let group = groups.first(where: { $0.memberUUIDs.contains(primary.uuid) }) {
            return devices.first { $0.uuid == group.coordinatorUUID } ?? primary
        }
        return primary
    }

    private func currentGroup() -> SonosGroup? {
        guard let primary else { return nil }
        return groups.first { $0.memberUUIDs.contains(primary.uuid) }
    }

    private func addToHistory(_ np: NowPlaying) {
        let entry = HistoryEntry(
            title: np.displayTitle,
            artist: np.artist,
            album: np.album,
            albumArtURL: np.albumArtURL,
            timestamp: Date(),
            trackURI: np.trackURI
        )
        // Avoid duplicates within a 10-minute window. SiriusXM sometimes
        // briefly switches to station-name metadata then back to the same
        // song, which used to produce duplicate entries.
        let dedupeWindow: TimeInterval = 600
        let now = Date()
        let isDuplicate = history.contains { existing in
            now.timeIntervalSince(existing.timestamp) < dedupeWindow &&
            existing.title.caseInsensitiveCompare(entry.title) == .orderedSame &&
            existing.artist.caseInsensitiveCompare(entry.artist) == .orderedSame
        }
        if isDuplicate { return }
        history.insert(entry, at: 0)
        if history.count > historyLimit {
            history = Array(history.prefix(historyLimit))
        }
        saveHistory()
    }

    // MARK: - History persistence
    // Lightweight — last N tracks stored in UserDefaults as JSON.

    private var historyDefaultsKey: String { "history.recent" }

    private func saveHistory() {
        let payload = history.map { entry in
            [
                "title": entry.title,
                "artist": entry.artist,
                "album": entry.album,
                "albumArtURL": entry.albumArtURL?.absoluteString ?? "",
                "timestamp": entry.timestamp.timeIntervalSince1970,
                "trackURI": entry.trackURI
            ] as [String: Any]
        }
        UserDefaults.standard.set(payload, forKey: historyDefaultsKey)
    }

    private func loadHistory() {
        guard let raw = UserDefaults.standard.array(forKey: historyDefaultsKey) as? [[String: Any]] else {
            return
        }
        history = raw.compactMap { dict in
            guard let title = dict["title"] as? String,
                  let artist = dict["artist"] as? String,
                  let album = dict["album"] as? String,
                  let ts = dict["timestamp"] as? TimeInterval,
                  let uri = dict["trackURI"] as? String else { return nil }
            let artStr = dict["albumArtURL"] as? String ?? ""
            return HistoryEntry(
                title: title,
                artist: artist,
                album: album,
                albumArtURL: artStr.isEmpty ? nil : URL(string: artStr),
                timestamp: Date(timeIntervalSince1970: ts),
                trackURI: uri
            )
        }
    }

    // MARK: - Topology parsing

    private struct ParsedTopology {
        let devices: [SonosDevice]
        let groups: [SonosGroup]
    }

    private func parseZoneGroupState(_ xml: String) -> ParsedTopology {
        logDebug("ZoneGroupState XML (\(xml.count) chars): \(xml)")
        // Find all <ZoneGroup ...>...</ZoneGroup> blocks
        let groupPattern = "<ZoneGroup\\s+([^>]*)>([\\s\\S]*?)</ZoneGroup>"
        // Match a ZoneGroupMember opening tag, capturing its attributes. We
        // allow either a self-closing tag (`/>`) or a tag with body (which
        // happens when the member has bonded satellites/subs as children).
        // `[^>]*?` is non-greedy and explicitly excludes `>`, so it can't
        // accidentally consume past the tag end — but it CAN contain `/` chars,
        // which appear in attribute values like Location="http://.../...".
        let memberPattern = "<ZoneGroupMember\\s+([^>]*?)/?>"
        guard let groupRegex = try? NSRegularExpression(pattern: groupPattern),
              let memberRegex = try? NSRegularExpression(pattern: memberPattern) else {
            return ParsedTopology(devices: [], groups: [])
        }

        var devices: [SonosDevice] = []
        var groups: [SonosGroup] = []
        let xmlRange = NSRange(xml.startIndex..<xml.endIndex, in: xml)

        groupRegex.enumerateMatches(in: xml, range: xmlRange) { match, _, _ in
            guard let match = match,
                  let attrsRange = Range(match.range(at: 1), in: xml),
                  let innerRange = Range(match.range(at: 2), in: xml) else { return }

            let attrs = String(xml[attrsRange])
            let inner = String(xml[innerRange])
            let coordinator = attrValue(attrs, "Coordinator") ?? ""
            let groupID = attrValue(attrs, "ID") ?? coordinator

            var memberUUIDs: [String] = []
            let innerRange2 = NSRange(inner.startIndex..<inner.endIndex, in: inner)
            memberRegex.enumerateMatches(in: inner, range: innerRange2) { mMatch, _, _ in
                guard let mMatch = mMatch,
                      let mAttrsRange = Range(mMatch.range(at: 1), in: inner) else { return }
                let mAttrs = String(inner[mAttrsRange])
                guard let uuid = attrValue(mAttrs, "UUID") else { return }
                memberUUIDs.append(uuid)

                // Build a SonosDevice from this member's attributes.
                let location = attrValue(mAttrs, "Location") ?? ""
                let host = extractHost(from: location)
                let zone = (attrValue(mAttrs, "ZoneName") ?? "")
                    .replacingOccurrences(of: "&apos;", with: "'")
                    .replacingOccurrences(of: "&amp;", with: "&")
                // Skip "invisible" devices (subs/satellite speakers bonded to a
                // parent — they have Invisible="1").
                let invisible = attrValue(mAttrs, "Invisible") == "1"
                if invisible { return }
                if host.isEmpty { return }

                let modelName = attrValue(mAttrs, "ModelName") ?? ""
                let modelNumber = attrValue(mAttrs, "ModelNumber") ?? ""
                if !devices.contains(where: { $0.uuid == uuid }) {
                    devices.append(SonosDevice(
                        uuid: uuid,
                        host: host,
                        zoneName: zone,
                        modelName: modelName,
                        modelNumber: modelNumber
                    ))
                }
            }

            groups.append(SonosGroup(
                id: groupID,
                coordinatorUUID: coordinator,
                memberUUIDs: memberUUIDs
            ))
        }

        return ParsedTopology(devices: devices, groups: groups)
    }

    private func attrValue(_ attrs: String, _ name: String) -> String? {
        let pattern = "\(NSRegularExpression.escapedPattern(for: name))=\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(attrs.startIndex..<attrs.endIndex, in: attrs)
        guard let match = regex.firstMatch(in: attrs, range: range),
              let r = Range(match.range(at: 1), in: attrs) else { return nil }
        return String(attrs[r])
    }

    private func extractHost(from location: String) -> String {
        // e.g. "http://192.168.1.84:1400/xml/device_description.xml"
        guard let url = URL(string: location) else { return "" }
        return url.host ?? ""
    }
}
