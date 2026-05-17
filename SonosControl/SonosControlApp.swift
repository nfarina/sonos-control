import SwiftUI
import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        logInfo("Application did finish launching")
        if NSApp.isActive {
            NSApp.deactivate()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        logInfo("Application will terminate")
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
            MenuBarView(sonos: sonos)
        } label: {
            Image(systemName: "hifispeaker.fill")
                // `.original` disables the default template behavior so our
                // foregroundStyle actually takes effect (otherwise macOS would
                // force monochrome menubar tinting).
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
