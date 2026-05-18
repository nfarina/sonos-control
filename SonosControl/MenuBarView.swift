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

    var body: some View {
        VStack(spacing: 10) {
            topBar
            if sonos.primaryZoneName.isEmpty {
                FirstLaunchPrompt(openSettings: openSettings)
            }
            NowPlayingCard(sonos: sonos)
            VolumeCard(sonos: sonos)
            SystemCard(sonos: sonos)
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

// MARK: - Volume card

private struct VolumeCard: View {
    @ObservedObject var sonos: SonosManager
    @State private var localVolume: Double = 30
    @State private var dragging = false
    @State private var pendingSend: Task<Void, Never>?

    var body: some View {
        Card {
            VStack(spacing: 6) {
                HStack {
                    Text("Volume")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text("\(Int(localVolume))%")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                HStack(spacing: 8) {
                    Image(systemName: "speaker.fill")
                        .foregroundStyle(.secondary)
                    Slider(
                        value: $localVolume,
                        in: 0...100,
                        onEditingChanged: { editing in
                            dragging = editing
                            if !editing {
                                // Final value when drag ends — always send.
                                pendingSend?.cancel()
                                Task { await sonos.setVolume(Int(localVolume)) }
                            }
                        }
                    )
                    Image(systemName: "speaker.wave.3.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { localVolume = Double(sonos.volume) }
        .onChange(of: sonos.volume) { _, newValue in
            // Don't fight the user mid-drag.
            if !dragging { localVolume = Double(newValue) }
        }
        .onChange(of: localVolume) { _, newValue in
            guard dragging else { return }
            // Throttle: cancel any in-flight send, schedule a new one ~50ms
            // out. The Sonos handles ~20 req/sec fine.
            pendingSend?.cancel()
            pendingSend = Task {
                try? await Task.sleep(nanoseconds: 50_000_000)
                if !Task.isCancelled {
                    await sonos.setVolume(Int(newValue))
                }
            }
        }
    }
}

// MARK: - System card (zones / satellites)

private struct SystemCard: View {
    @ObservedObject var sonos: SonosManager

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Text("System")
                    .font(.subheadline.weight(.medium))
                    .padding(.bottom, 2)

                if let primary = sonos.primary {
                    ZoneRow(
                        device: primary,
                        isPrimary: true,
                        isOn: true,
                        toggle: {}
                    )
                } else {
                    Text("No zones discovered yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(sonos.satellites) { device in
                    ZoneRow(
                        device: device,
                        isPrimary: false,
                        isOn: sonos.isGrouped(device),
                        toggle: { Task { await sonos.toggleSatellite(device) } }
                    )
                }
            }
        }
    }
}

private struct ZoneRow: View {
    let device: SonosDevice
    let isPrimary: Bool
    let isOn: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.isPortable ? "hifispeaker" : "hifispeaker.2")
                .frame(width: 24, height: 24)
                .foregroundStyle(isPrimary || isOn ? Color.accentColor : .secondary)
                .background(
                    Circle()
                        .fill((isPrimary || isOn) ? Color.accentColor.opacity(0.15) : Color.clear)
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
                Toggle("", isOn: Binding(get: { isOn }, set: { _ in toggle() }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !isPrimary { toggle() }
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

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
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
