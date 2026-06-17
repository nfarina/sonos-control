import SwiftUI
import Sparkle

/// Top-level Settings content. Tab selection is driven externally by
/// `SettingsWindowCoordinator` (which owns an NSToolbar at the top of the
/// window), and this view just swaps content based on `selection.selected`.
struct SettingsView: View {
    @ObservedObject var sonos: SonosManager
    @ObservedObject var hotkeys: HotkeyManager
    let updater: SPUUpdater
    @ObservedObject var selection: SettingsTabSelection

    var body: some View {
        Group {
            switch selection.selected {
            case .general:   GeneralSettingsTab(sonos: sonos)
            case .shortcuts: ShortcutsSettingsTab(hotkeys: hotkeys)
            case .lyrics:    LyricsSettingsTab()
            case .updates:   UpdatesSettingsTab(updater: updater)
            case .about:     AboutSettingsTab()
            }
        }
        .frame(width: 480, height: 400)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @ObservedObject var sonos: SonosManager
    @State private var selectedPrimary: String = ""

    var body: some View {
        Form {
            Section {
                Picker("Primary Zone", selection: $selectedPrimary) {
                    if sonos.devices.isEmpty {
                        Text("Discovering…").tag("")
                    } else {
                        ForEach(sonos.devices) { device in
                            Text(device.zoneName).tag(device.zoneName)
                        }
                    }
                }
                .pickerStyle(.menu)
                .disabled(sonos.devices.isEmpty)
                .help("Volume and play/pause target this zone. Other zones appear as toggleable satellites in the main menu.")

                Button("Rediscover Zones") {
                    Task { await sonos.refreshTopology() }
                }
                .disabled(sonos.isDiscovering)
            } header: {
                Text("Primary Zone")
            } footer: {
                if sonos.devices.isEmpty {
                    Text("No Sonos devices found yet. Make sure you're on the same network and grant Local Network permission if prompted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Volume and play/pause always target the primary zone. Toggle other zones in or out of its group from the main menu.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !sonos.devices.isEmpty {
                Section {
                    ForEach(sonos.devices) { device in
                        Toggle(isOn: hiddenBinding(for: device)) {
                            HStack {
                                Text(device.zoneName)
                                Text(device.modelName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                } header: {
                    Text("Visible Zones")
                } footer: {
                    Text("Uncheck zones you never want to see in the System card.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { selectedPrimary = sonos.primaryZoneName }
        .onChange(of: selectedPrimary) { _, newValue in
            if !newValue.isEmpty && newValue != sonos.primaryZoneName {
                sonos.primaryZoneName = newValue
            }
        }
        .onChange(of: sonos.primaryZoneName) { _, newValue in
            if newValue != selectedPrimary {
                selectedPrimary = newValue
            }
        }
    }

    /// Inverted binding — UI shows "Visible" (true = visible), storage tracks
    /// hidden UUIDs (true = hidden). Easier to reason about checkmarks.
    private func hiddenBinding(for device: SonosDevice) -> Binding<Bool> {
        Binding(
            get: { !sonos.hiddenZoneUUIDs.contains(device.uuid) },
            set: { isVisible in
                var hidden = sonos.hiddenZoneUUIDs
                if isVisible {
                    hidden.remove(device.uuid)
                } else {
                    hidden.insert(device.uuid)
                }
                sonos.hiddenZoneUUIDs = hidden
            }
        )
    }
}

// MARK: - Shortcuts

private struct ShortcutsSettingsTab: View {
    @ObservedObject var hotkeys: HotkeyManager
    @State private var editingAction: HotkeyAction?

    var body: some View {
        Form {
            Section {
                ForEach(globalActions) { action in
                    shortcutRow(action)
                }
            } header: {
                Text("Global")
            } footer: {
                Text("Global shortcuts work from any app. Default of F8 means Fn+F8, or \"Use F1, F2, etc. keys as standard function keys\" enabled in System Settings → Keyboard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(inAppActions) { action in
                    shortcutRow(action)
                }
            } header: {
                Text("In Menu")
            } footer: {
                Text("These shortcuts only fire while the Sonos Control menu is open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var globalActions: [HotkeyAction] {
        HotkeyAction.allCases.filter { $0.scope == .global }
    }

    private var inAppActions: [HotkeyAction] {
        HotkeyAction.allCases.filter { $0.scope == .inApp }
    }

    @ViewBuilder
    private func shortcutRow(_ action: HotkeyAction) -> some View {
        HStack {
            Text(action.displayName)
            Spacer()
            Button {
                editingAction = action
            } label: {
                Text(hotkeys.bindings[action]?.displayString ?? "—")
                    .font(.system(.body, design: .monospaced))
                    .frame(minWidth: 80)
            }
            .popover(isPresented: Binding(
                get: { editingAction == action },
                set: { if !$0 { editingAction = nil } }
            )) {
                KeyCapturePopover(
                    title: action.displayName,
                    onCapture: { keyCode, flags in
                        let mods = HotkeyManager.carbonFlags(from: flags)
                        hotkeys.setBinding(action, keyCode: keyCode, modifiers: mods)
                        editingAction = nil
                    },
                    onCancel: { editingAction = nil }
                )
            }
            Button {
                hotkeys.reset(action)
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .help("Restore default")
        }
    }
}

private struct KeyCapturePopover: View {
    let title: String
    let onCapture: (UInt32, NSEvent.ModifierFlags) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.subheadline.weight(.medium))
            Text("Press the new shortcut")
                .font(.caption)
                .foregroundStyle(.secondary)
            KeyCaptureRepresentable(onCapture: onCapture, onCancel: onCancel)
                .frame(width: 240, height: 0)
            Text("Esc to cancel")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
    }
}

// MARK: - Lyrics

private struct LyricsSettingsTab: View {
    @AppStorage(LyricsService.providerDefaultsKey) private var providerRaw = LyricsProvider.lrclib.rawValue
    @AppStorage(LyricsService.geminiKeyDefaultsKey) private var geminiKey = ""
    @AppStorage(LyricsService.exaKeyDefaultsKey) private var exaKey = ""

    private var provider: LyricsProvider {
        LyricsProvider(rawValue: providerRaw) ?? .lrclib
    }

    var body: some View {
        Form {
            Section {
                Picker("Lyrics Source", selection: $providerRaw) {
                    ForEach(LyricsProvider.allCases) { p in
                        Text(p.displayName).tag(p.rawValue)
                    }
                }
                .pickerStyle(.menu)
            } footer: {
                Text(sourceFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if provider == .gemini {
                Section {
                    SecureField("Gemini API Key", text: $geminiKey)
                        .textFieldStyle(.roundedBorder)
                    Link("Get a free API key at aistudio.google.com",
                         destination: URL(string: "https://aistudio.google.com/apikey")!)
                        .font(.caption)
                } header: {
                    Text("Google Gemini")
                } footer: {
                    Text("Your key is stored locally and only ever sent to Google's API. Gemini Flash Lite is extremely cheap — lyric lookups cost a fraction of a cent.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if provider == .exa {
                Section {
                    SecureField("Exa API Key", text: $exaKey)
                        .textFieldStyle(.roundedBorder)
                    Link("Get an API key at dashboard.exa.ai",
                         destination: URL(string: "https://dashboard.exa.ai/api-keys")!)
                        .font(.caption)
                } header: {
                    Text("Exa")
                } footer: {
                    Text("Your key is stored locally and only ever sent to Exa's API. Exa's search-and-extract is the most reliable for obscure / indie tracks, at about half a cent per lookup. Falls back to LRCLIB if a request fails.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var sourceFooter: String {
        switch provider {
        case .lrclib:
            return "LRCLIB is a free, open lyrics database. No account needed."
        case .gemini:
            return "Gemini Flash Lite, grounded by Google Search, finds lyrics for most tracks. Falls back to LRCLIB if a request fails."
        case .exa:
            return "Exa search-and-extract is the most reliable for obscure / indie tracks. Falls back to LRCLIB if a request fails."
        }
    }
}

// MARK: - Updates

private struct UpdatesSettingsTab: View {
    let updater: SPUUpdater
    @State private var automaticChecks: Bool

    init(updater: SPUUpdater) {
        self.updater = updater
        _automaticChecks = State(initialValue: updater.automaticallyChecksForUpdates)
    }

    var body: some View {
        Form {
            Section {
                CheckForUpdatesView(updater: updater)
                Toggle("Automatically check for updates", isOn: $automaticChecks)
                    .onChange(of: automaticChecks) { _, newValue in
                        updater.automaticallyChecksForUpdates = newValue
                    }
            } footer: {
                Text("Updates are delivered via Sparkle from this app's release feed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About

private struct AboutSettingsTab: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "hifispeaker.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .padding(.top, 20)
            Text("Sonos Control")
                .font(.title2.weight(.semibold))
            Text("Version \(version) (\(build))")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("A minimal, fast Sonos controller for macOS.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.top, 4)

            Spacer()

            VStack(spacing: 4) {
                Text("Made by Nick Farina")
                    .font(.callout)
                Link("github.com/nfarina/SonosControl",
                     destination: URL(string: "https://github.com/nfarina/SonosControl")!)
                    .font(.caption)
            }
            .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
