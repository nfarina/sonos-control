import AppKit
import SwiftUI
import Combine

/// Identifies a Settings tab. Drives both the NSToolbar and the SwiftUI
/// content view that swaps based on selection.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, shortcuts, lyrics, updates, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:   return "General"
        case .shortcuts: return "Shortcuts"
        case .lyrics:    return "Lyrics"
        case .updates:   return "Updates"
        case .about:     return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general:   return "gear"
        case .shortcuts: return "keyboard"
        case .lyrics:    return "text.quote"
        case .updates:   return "arrow.triangle.2.circlepath"
        case .about:     return "info.circle"
        }
    }

    var toolbarItemIdentifier: NSToolbarItem.Identifier {
        NSToolbarItem.Identifier("SettingsTab.\(rawValue)")
    }
}

/// Observable selection bridge — the NSToolbar updates this, the SwiftUI
/// content tree observes it.
@MainActor
final class SettingsTabSelection: ObservableObject {
    @Published var selected: SettingsTab = .general
}

/// Hand-rolled NSWindow for Settings. Replaces SwiftUI's `Settings` scene,
/// which has two problems for a menubar-only app:
///   • macOS auto-restores it on every launch after the user opens it once
///   • SwiftUI gives no programmatic way to suppress that restoration
/// A custom NSWindow we own has neither problem. We also get the proper
/// macOS preferences-style toolbar with large icons at the top.
@MainActor
final class SettingsWindowCoordinator: NSObject, NSWindowDelegate, NSToolbarDelegate {
    private static let defaultSize = NSSize(width: 480, height: 400)

    private let makeContentView: @MainActor (SettingsTabSelection) -> NSView
    private(set) var window: NSWindow?
    let selection = SettingsTabSelection()

    init(makeContentView: @escaping @MainActor (SettingsTabSelection) -> NSView) {
        self.makeContentView = makeContentView
        super.init()
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        window.title = "Sonos Control Settings"
        window.contentView = makeContentView(selection)
        window.center()

        // Preferences-style toolbar: large icons on top, content below.
        let toolbar = NSToolbar(identifier: "SonosControl.SettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.selectedItemIdentifier = SettingsTab.general.toolbarItemIdentifier
        window.toolbar = toolbar
        window.toolbarStyle = .preference

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Hide rather than destroy — subsequent opens are instant and any
        // in-flight UI state (key-capture popovers, etc.) survives.
        guard sender === window else { return true }
        sender.orderOut(nil)
        return false
    }

    // MARK: - NSToolbarDelegate

    nonisolated func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsTab.allCases.map(\.toolbarItemIdentifier)
    }

    nonisolated func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    nonisolated func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    nonisolated func toolbar(_ toolbar: NSToolbar,
                             itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                             willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let tab = SettingsTab.allCases.first(where: { $0.toolbarItemIdentifier == itemIdentifier })
        else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = tab.title
        item.paletteLabel = tab.title
        item.image = NSImage(systemSymbolName: tab.systemImage, accessibilityDescription: tab.title)
        item.target = self
        item.action = #selector(toolbarItemSelected(_:))
        return item
    }

    @objc private func toolbarItemSelected(_ sender: NSToolbarItem) {
        guard let tab = SettingsTab.allCases.first(where: { $0.toolbarItemIdentifier == sender.itemIdentifier })
        else { return }
        selection.selected = tab
    }
}
