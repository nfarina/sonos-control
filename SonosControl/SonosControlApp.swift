import SwiftUI
import Cocoa
import Sparkle

class AppDelegate: NSObject, NSApplicationDelegate {
    lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    /// Set by SonosControlApp after init so the coordinator can build the
    /// Settings view with the right state objects.
    var settingsContentFactory: (@MainActor (SettingsTabSelection) -> NSView)?

    lazy var settingsCoordinator: SettingsWindowCoordinator = {
        SettingsWindowCoordinator(makeContentView: { [weak self] selection in
            self?.settingsContentFactory?(selection) ?? NSView()
        })
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        logInfo("Application did finish launching")
        if NSApp.isActive {
            NSApp.deactivate()
        }
        updaterController.startUpdater()
    }

    func applicationWillTerminate(_ notification: Notification) {
        logInfo("Application will terminate")
    }

    @objc func showSettings() {
        settingsCoordinator.show()
    }
}

@main
struct SonosControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var sonos: SonosManager

    private let logger = Logger.shared
    private let hotkeys: HotkeyManager

    init() {
        let manager = SonosManager()
        _sonos = StateObject(wrappedValue: manager)
        hotkeys = HotkeyManager()

        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        logInfo("System: \(osVersion), SonosControl \(appVersion)")
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(sonos: sonos, openSettings: { appDelegate.showSettings() })
                .onAppear {
                    // Wire the factory once; the coordinator will call it lazily
                    // on first Settings open.
                    if appDelegate.settingsContentFactory == nil {
                        appDelegate.settingsContentFactory = { [sonos, hotkeys, appDelegate] selection in
                            NSHostingView(rootView: SettingsView(
                                sonos: sonos,
                                hotkeys: hotkeys,
                                updater: appDelegate.updaterController.updater,
                                selection: selection
                            ))
                        }
                    }
                }
        } label: {
            Image(systemName: "hifispeaker.fill")
                // `.original` disables the default template behavior so our
                // foregroundStyle actually takes effect (otherwise macOS
                // would force monochrome menubar tinting).
                .renderingMode(.original)
                .symbolRenderingMode(.palette)
                .foregroundStyle(menuIconColor)
                .font(.system(size: 18, weight: .medium))
                .imageScale(.large)
        }
        .menuBarExtraStyle(.window)
    }

    /// Always render the hifispeaker — state is conveyed by tint:
    ///   • not loaded yet or offline → secondary (greyed out)
    ///   • playing → vibrant blue
    ///   • paused / stopped → primary (black / white per appearance)
    private var menuIconColor: Color {
        if !sonos.hasLoadedState || sonos.isOffline { return .secondary }
        if sonos.isPlaying { return Color(red: 0.05, green: 0.35, blue: 0.85) }
        return .primary
    }
}
