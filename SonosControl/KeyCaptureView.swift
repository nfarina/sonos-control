import SwiftUI
import AppKit
import Carbon

/// SwiftUI wrapper around an NSView that grabs first responder and captures
/// the next keystroke. Calls `onCapture` with the raw Carbon keycode and the
/// modifier flags that were held down.
struct KeyCaptureRepresentable: NSViewRepresentable {
    let onCapture: (UInt32, NSEvent.ModifierFlags) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let v = KeyCaptureNSView()
        v.onCapture = onCapture
        v.onCancel = onCancel
        return v
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {}
}

final class KeyCaptureNSView: NSView {
    var onCapture: ((UInt32, NSEvent.ModifierFlags) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            onCancel?()
            return
        }
        onCapture?(UInt32(event.keyCode), event.modifierFlags)
    }

    override func flagsChanged(with event: NSEvent) {
        // Ignore standalone modifier presses.
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
