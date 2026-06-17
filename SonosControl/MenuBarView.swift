import SwiftUI
import AppKit

/// Opens a search for `artist title` in the Apple Music app. The `music://`
/// URL scheme is handled by the Music.app on macOS and avoids the web detour
/// that `https://music.apple.com/...` takes.
func openInAppleMusic(artist: String, title: String) {
    let query = "\(artist) \(title)".trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty,
          let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
          let url = URL(string: "music://music.apple.com/search?term=\(encoded)") else { return }
    NSWorkspace.shared.open(url)
}

struct MenuBarView: View {
    @ObservedObject var sonos: SonosManager
    /// Provided by SonosControlApp — opens the custom Settings NSWindow.
    let openSettings: () -> Void

    @State private var showingHistory = false
    @State private var showingFavorites = false
    /// Persisted across menu open/close so the lyrics panel stays where the
    /// user left it. Lyrics are only fetched while this panel is actually on
    /// screen (i.e. menu open + toggle on).
    @AppStorage("lyrics.panelVisible") private var showLyricsPanel = false

    var body: some View {
        VStack(spacing: 10) {
            topBar
            if sonos.primaryZoneName.isEmpty {
                FirstLaunchPrompt(openSettings: openSettings)
            }
            NowPlayingCard(sonos: sonos)
            SystemCard(sonos: sonos)
            if showLyricsPanel {
                LyricsCard(sonos: sonos)
            }
        }
        .padding(12)
        .frame(width: 340)
        .onAppear {
            sonos.startPolling()
            Task { await sonos.refreshNowPlaying() }
        }
        .onDisappear {
            sonos.stopPolling()
        }
        .popover(isPresented: $showingHistory, arrowEdge: .top) {
            HistoryPopover(sonos: sonos)
        }
        .popover(isPresented: $showingFavorites, arrowEdge: .top) {
            FavoritesPopover(sonos: sonos)
        }
    }

    // Keyboard shortcuts (Cmd+P, Cmd+=, Cmd+−) are dispatched by HotkeyManager
    // via NSEvent.addLocalMonitorForEvents and routed through the SonosManager
    // notification subscriptions. No SwiftUI .keyboardShortcut bindings needed.

    private var topBar: some View {
        HStack(spacing: 14) {
            Button {
                showingFavorites.toggle()
            } label: {
                Image(systemName: "star")
                    .imageScale(.medium)
            }
            .help("Favorites")

            Button {
                showingHistory.toggle()
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .imageScale(.medium)
            }
            .help("Recently played")

            Button {
                showLyricsPanel.toggle()
            } label: {
                Image(systemName: "text.quote")
                    .imageScale(.medium)
                    .foregroundStyle(showLyricsPanel ? Color.accentColor : Color.primary)
            }
            .help(showLyricsPanel ? "Hide lyrics" : "Show lyrics")

            if sonos.isDiscovering {
                ProgressView()
                    .controlSize(.small)
                    .help("Discovering zones")
            }

            FreshnessIndicator(sonos: sonos)

            Spacer()

            if let err = sonos.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Menu {
                Button("Settings…") { openSettings() }
                    .keyboardShortcut(",", modifiers: .command)
                Divider()
                Button("Open Log File") { Logger.shared.openLogFile() }
                Divider()
                Button("Quit Sonos Control") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .imageScale(.medium)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 4)
    }
}

// MARK: - First launch prompt

/// Shown at the top of the menu when no primary zone has been configured.
/// Uses SettingsLink so a single click takes the user to General settings to
/// pick their primary zone.
private struct FirstLaunchPrompt: View {
    let openSettings: () -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Welcome to Sonos Control")
                    .font(.subheadline.weight(.semibold))
                Text("Pick a primary zone in Settings to get started.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    openSettings()
                } label: {
                    Label("Open Settings", systemImage: "gear")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.regular)
            }
        }
    }
}

// MARK: - Now Playing card

private struct NowPlayingCard: View {
    @ObservedObject var sonos: SonosManager
    @State private var showingTrackDetail = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Button {
                        showingTrackDetail.toggle()
                    } label: {
                        AlbumArtView(url: sonos.nowPlaying.albumArtURL, size: 64)
                    }
                    .buttonStyle(.plain)
                    .help("Show track details")
                    .popover(isPresented: $showingTrackDetail, arrowEdge: .leading) {
                        TrackDetailPopover(np: sonos.nowPlaying)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayTitle)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if !displaySubtitle.isEmpty {
                            Text(displaySubtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        if !displayTertiary.isEmpty {
                            Text(displayTertiary)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    Spacer()
                }

                TransportControls(sonos: sonos)

                if !sonos.nowPlaying.isRadioStream && sonos.nowPlaying.duration > 0 {
                    PositionBar(np: sonos.nowPlaying)
                }
            }
        }
    }

    private var displayTitle: String {
        let t = sonos.nowPlaying.displayTitle
        if t.isEmpty {
            return sonos.primary == nil ? "Searching for Sonos…" : "Nothing playing"
        }
        return t
    }

    private var displaySubtitle: String {
        let s = sonos.nowPlaying.displaySubtitle
        // Fall back to the zone name only when there's truly no artist info.
        if s.isEmpty && displayTertiary.isEmpty && sonos.primary != nil {
            return sonos.primary?.zoneName ?? ""
        }
        return s
    }

    private var displayTertiary: String {
        sonos.nowPlaying.displayTertiary
    }
}

private struct AlbumArtView: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        placeholder
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .failure:
                        placeholder
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.separator, lineWidth: 0.5)
        )
    }

    private var placeholder: some View {
        ZStack {
            Color.secondary.opacity(0.18)
            Image(systemName: "music.note")
                .foregroundStyle(.secondary)
                .imageScale(.large)
        }
    }
}

private struct TransportControls: View {
    @ObservedObject var sonos: SonosManager

    var body: some View {
        HStack(spacing: 24) {
            Spacer()
            Button {
                Task { await sonos.previous() }
            } label: {
                Image(systemName: "backward.fill")
                    .imageScale(.large)
            }
            .disabled(sonos.nowPlaying.isRadioStream)

            Button {
                Task { await sonos.togglePlayPause() }
            } label: {
                Image(systemName: sonos.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 26, weight: .semibold))
            }
            .help("Play/Pause")

            Button {
                Task { await sonos.next() }
            } label: {
                Image(systemName: "forward.fill")
                    .imageScale(.large)
            }
            .disabled(sonos.nowPlaying.isRadioStream)
            Spacer()
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
    }
}

private struct PositionBar: View {
    let np: NowPlaying

    var body: some View {
        VStack(spacing: 2) {
            ProgressView(value: min(np.position, np.duration), total: max(np.duration, 1))
                .progressViewStyle(.linear)
                .tint(.accentColor)
            HStack {
                Text(format(np.position))
                Spacer()
                Text(format(np.duration))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func format(_ t: TimeInterval) -> String {
        let total = Int(t)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - System card (zones + per-zone volume)

private struct SystemCard: View {
    @ObservedObject var sonos: SonosManager

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                Text("System")
                    .font(.subheadline.weight(.medium))
                    .padding(.bottom, 8)

                if let primary = sonos.primary {
                    ZoneRow(sonos: sonos, device: primary, isPrimary: true)
                } else {
                    Text("No zones discovered yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(sonos.satellites) { device in
                    Divider().padding(.vertical, 8)
                    ZoneRow(sonos: sonos, device: device, isPrimary: false)
                }
            }
        }
    }
}

private struct ZoneRow: View {
    @ObservedObject var sonos: SonosManager
    let device: SonosDevice
    let isPrimary: Bool

    private var isActive: Bool { isPrimary || sonos.isGrouped(device) }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: device.isPortable ? "hifispeaker" : "hifispeaker.2")
                    .frame(width: 24, height: 24)
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                    .background(
                        Circle()
                            .fill(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
                            .frame(width: 28, height: 28)
                    )

                Text(device.zoneName)
                    .font(.body)

                Spacer()

                if isPrimary {
                    Text("Primary")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                } else {
                    Toggle("", isOn: Binding(
                        get: { sonos.isGrouped(device) },
                        set: { _ in Task { await sonos.toggleSatellite(device) } }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                }
            }

            // Per-zone volume slider — only for zones that are actually
            // playing (primary, or a satellite grouped with it).
            if isActive {
                ZoneVolumeSlider(sonos: sonos, device: device)
            }
        }
    }
}

private struct ZoneVolumeSlider: View {
    @ObservedObject var sonos: SonosManager
    let device: SonosDevice
    @State private var localVolume: Double = 0
    @State private var dragging = false
    @State private var pendingSend: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill")
                .foregroundStyle(.secondary)
                .imageScale(.small)
            Slider(
                value: $localVolume,
                in: 0...100,
                onEditingChanged: { editing in
                    dragging = editing
                    if !editing {
                        pendingSend?.cancel()
                        Task { await sonos.setZoneVolume(device, Int(localVolume)) }
                    }
                }
            )
            Image(systemName: "speaker.wave.3.fill")
                .foregroundStyle(.secondary)
                .imageScale(.small)
            Text("\(Int(localVolume))%")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)
        }
        .onAppear { localVolume = Double(sonos.volume(for: device)) }
        .onChange(of: sonos.volume(for: device)) { _, newValue in
            if !dragging { localVolume = Double(newValue) }
        }
        .onChange(of: localVolume) { _, newValue in
            guard dragging else { return }
            // Throttle live drags — cancel any in-flight send, schedule a new
            // one ~50ms out. Sonos handles ~20 req/sec fine.
            pendingSend?.cancel()
            pendingSend = Task {
                try? await Task.sleep(nanoseconds: 50_000_000)
                if !Task.isCancelled {
                    await sonos.setZoneVolume(device, Int(newValue))
                }
            }
        }
    }
}

// MARK: - Popovers

private struct HistoryPopover: View {
    @ObservedObject var sonos: SonosManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recently Played")
                    .font(.headline)
                Spacer()
                if !sonos.history.isEmpty {
                    Button("Clear") { sonos.clearHistory() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            .padding(.bottom, 4)

            if sonos.history.isEmpty {
                Text("Nothing yet — songs you hear will show up here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(sonos.history) { entry in
                    Button {
                        openInAppleMusic(artist: entry.artist, title: entry.title)
                    } label: {
                        HStack(spacing: 10) {
                            AlbumArtView(url: entry.albumArtURL, size: 36)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.title)
                                    .font(.callout)
                                    .lineLimit(1)
                                    .foregroundStyle(.primary)
                                if !entry.artist.isEmpty {
                                    Text(entry.artist)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Text(relativeTime(entry.timestamp))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Image(systemName: "arrow.up.right.square")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open “\(entry.title)” by \(entry.artist) in Apple Music")
                }
            }
        }
        .padding(12)
        .frame(width: 320)
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct FavoritesPopover: View {
    @ObservedObject var sonos: SonosManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Favorites")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await sonos.fetchFavorites() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
            .padding(.bottom, 4)

            // Always render the scroll area so the popover claims a stable
            // size from the moment it opens. If favorites are still loading
            // we show a placeholder inside.
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if sonos.favorites.isEmpty {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Loading favorites…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    } else {
                        ForEach(sonos.favorites) { fav in
                            Button {
                                Task { await sonos.playFavorite(fav) }
                            } label: {
                                HStack(spacing: 10) {
                                    AlbumArtView(url: fav.albumArtURL, size: 36)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(fav.title)
                                            .font(.callout)
                                            .lineLimit(1)
                                            .foregroundStyle(.primary)
                                        if !fav.description.isEmpty {
                                            Text(fav.description)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 2)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 280, maxHeight: 400)
        }
        .padding(12)
        .frame(width: 320)
        .task {
            if sonos.favorites.isEmpty {
                await sonos.fetchFavorites()
            }
        }
    }
}

// MARK: - Lyrics panel (inline, persistent)

private struct LyricsCard: View {
    @ObservedObject var sonos: SonosManager

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Lyrics")
                        .font(.subheadline.weight(.medium))
                    if let source = lyricsSource {
                        Text(source.badgeName)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                            .help("Lyrics from \(source.badgeName)")
                    }
                    Spacer()
                    Button {
                        sonos.fetchLyrics(force: true)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .imageScale(.small)
                    }
                    .buttonStyle(.borderless)
                    .help("Reload lyrics")
                }

                // Fixed-height box: lyrics scroll within it, and the panel
                // height stays constant as the song changes or lyrics load.
                Group {
                    if let text = lyricsText {
                        ScrollView {
                            Text(text)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        // Loading / placeholder states are centered in the box.
                        placeholderContent
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(height: 240)
            }
        }
        .onChange(of: "\(sonos.nowPlaying.artist)|\(sonos.nowPlaying.displayTitle)", initial: true) {
            // Trigger when the panel appears and whenever the song changes
            // while it's visible. The fetch itself runs on a manager-owned
            // task, so it survives the menu closing. Keyed on artist+title
            // (not trackURI) so it refires for radio, where the stream URI
            // stays constant across songs.
            sonos.fetchLyrics()
        }
    }

    /// The actual lyrics text to display, or nil if we're in a loading /
    /// placeholder state (which gets centered instead of scrolled).
    private var lyricsText: String? {
        if case .loaded(let lyrics) = sonos.lyricsState, !lyrics.instrumental,
           let text = lyrics.plain ?? lyrics.synced {
            return Self.stripTimestamps(text)
        }
        return nil
    }

    /// Source of the currently-shown lyrics, for the header badge. Only set
    /// once real lyrics are loaded.
    private var lyricsSource: LyricsProvider? {
        if case .loaded(let lyrics) = sonos.lyricsState, !lyrics.instrumental,
           (lyrics.plain ?? lyrics.synced) != nil {
            return lyrics.source
        }
        return nil
    }

    @ViewBuilder
    private var placeholderContent: some View {
        switch sonos.lyricsState {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Finding lyrics…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .loaded(let lyrics):
            // Only reached when instrumental or no usable text.
            if lyrics.instrumental {
                placeholder("This track is instrumental.", icon: "music.note")
            } else {
                placeholder("No lyrics available for this track.", icon: "text.quote")
            }
        case .notFound:
            placeholder("No lyrics found for this track.", icon: "text.quote")
        case .noSong:
            placeholder("Waiting for a song…", icon: "dot.radiowaves.left.and.right")
        case .failed(let message):
            placeholder(message, icon: "exclamationmark.triangle")
        }
    }

    private func placeholder(_ text: String, icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    /// Remove LRC timestamp tags like `[00:24.56]` or `[01:00]` from a line of
    /// text. Some LRCLIB entries put synced text in the "plain" field, so we
    /// always run this. Section markers like `[Chorus]` are preserved because
    /// the pattern only matches numeric `mm:ss(.xx)` tags.
    static func stripTimestamps(_ text: String) -> String {
        let pattern = "\\[\\d{1,2}:\\d{2}(?:[.:]\\d{1,3})?\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let s = String(line)
                let range = NSRange(s.startIndex..<s.endIndex, in: s)
                let cleaned = regex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
                return cleaned.trimmingCharacters(in: .whitespaces)
            }
            .joined(separator: "\n")
    }
}

// MARK: - Track detail popover (full-size art + open in Music)

private struct TrackDetailPopover: View {
    let np: NowPlaying

    var body: some View {
        VStack(alignment: .center, spacing: 12) {
            AlbumArtView(url: np.albumArtURL, size: 280)

            VStack(spacing: 2) {
                Text(np.displayTitle.isEmpty ? "Nothing playing" : np.displayTitle)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                if !np.artist.isEmpty {
                    Text(np.artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                if !np.displayTertiary.isEmpty {
                    Text(np.displayTertiary)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)

            if canSearch {
                Button {
                    openInAppleMusic(artist: np.artist, title: np.displayTitle)
                } label: {
                    Label("Open in Apple Music", systemImage: "arrow.up.right.square")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.regular)
            }
        }
        .padding(16)
        .frame(width: 312)
    }

    /// Only useful to search Music when we have actual song info — not when
    /// the screen is just showing a station placeholder.
    private var canSearch: Bool {
        !np.artist.isEmpty && !np.displayTitle.isEmpty
    }
}

// MARK: - Freshness indicator

/// Tiny "5s ago" label next to the refresh button. Only appears once the data
/// is stale enough to be worth surfacing (>4 sec). Updates once per second via
/// TimelineView — no Combine timer plumbing required.
private struct FreshnessIndicator: View {
    @ObservedObject var sonos: SonosManager
    /// Fixed anchor for the periodic schedule, captured once. Using `.now`
    /// inline would rebuild the timeline schedule on every render.
    @State private var anchor = Date()

    var body: some View {
        TimelineView(.periodic(from: anchor, by: 1)) { context in
            if let last = sonos.lastPolledAt {
                let age = Int(context.date.timeIntervalSince(last))
                if age >= 4 {
                    Text("\(age)s ago")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .help("Last refreshed \(age) seconds ago")
                        .transition(.opacity)
                }
            } else if sonos.hasLoadedState == false && !sonos.isDiscovering {
                // Initial load hasn't completed; refresh button shows spinner.
                EmptyView()
            }
        }
    }
}

// MARK: - Card wrapper

private struct Card<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.background.secondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.separator.opacity(0.6), lineWidth: 0.5)
            )
    }
}
