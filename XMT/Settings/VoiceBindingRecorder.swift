import AppKit
import KeyboardShortcuts
import SwiftUI

/// XMT-owned capture UI. Escape, modified Escape, and Fn chords are captured;
/// cancellation is available only through the explicit button.
struct VoiceBindingRecorder: View {
    let title: String
    let action: VoiceBindingAction
    let value: ShortcutDTO
    let isManaged: Bool
    let isRecording: Bool
    let isOtherBindingBusy: Bool
    let begin: () -> Void
    let cancel: () -> Void
    let commit: (ShortcutDTO) async -> String?
    var didCommit: (ShortcutDTO) -> Void = { _ in }

    @State private var diagnostic: String?
    @State private var isCommitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            LabeledContent(title) {
                HStack {
                    Text(Self.display(value)).monospacedDigit().accessibilityLabel("Current binding: \(Self.display(value))")
                    if isRecording {
                        KeyDownCaptureView(captured: { captured($0) }, unsupported: {
                            diagnostic = "That key cannot be used as a global shortcut."
                        })
                        .frame(width: 1, height: 1)
                        .accessibilityLabel("Shortcut capture")
                        Text("Press a key chord…").foregroundStyle(.secondary)
                        Button("Cancel") { cancel() }
                            .accessibilityHint("Stop editing without changing the binding")
                    } else {
                        if action == .holdToTalk {
                            Button("Fn") { submit(.modifierHold("fn")) }
                                .accessibilityHint("Use the Function modifier by itself")
                        }
                        Button("Record") { diagnostic = nil; begin() }
                            .accessibilityHint("Capture the next key chord; use the Cancel button to stop editing")
                        Button("Clear") { submit(.unbound) }
                            .accessibilityHint("Unbind this action")
                    }
                }
            }
            if let diagnostic { Text(diagnostic).font(.caption).foregroundStyle(.red).accessibilityLabel("Binding error: \(diagnostic)") }
        }
        .disabled(isManaged || isCommitting || isOtherBindingBusy)
    }

    private func captured(_ shortcut: ShortcutDTO) { submit(shortcut) }
    private func submit(_ shortcut: ShortcutDTO) {
        isCommitting = true
        Task { @MainActor in
            diagnostic = await commit(shortcut)
            if diagnostic == nil { didCommit(shortcut) }
            isCommitting = false
        }
    }

    static func display(_ value: ShortcutDTO) -> String {
        switch value {
        case .unbound: return "Unbound"
        case .modifierHold: return "Fn"
        case .fnChord(let key): return "Fn–" + (key.lowercased() == "escape" ? "Esc" : key.uppercased())
        case .key(let key, let modifiers):
            let symbols = ["control": "⌃", "option": "⌥", "shift": "⇧", "command": "⌘"]
            return modifiers.compactMap { symbols[$0.lowercased()] }.joined() + (key.lowercased() == "escape" ? "Esc" : key.uppercased())
        }
    }
}

private struct KeyDownCaptureView: NSViewRepresentable {
    let captured: (ShortcutDTO) -> Void
    let unsupported: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(captured: captured, unsupported: unsupported) }
    func makeNSView(context: Context) -> CaptureView { let view = CaptureView(); view.coordinator = context.coordinator; return view }
    func updateNSView(_ view: CaptureView, context: Context) { view.coordinator = context.coordinator }
    final class Coordinator {
        let captured: (ShortcutDTO) -> Void; let unsupported: () -> Void
        var decoder = VoiceBindingCaptureDecoder()
        init(captured: @escaping (ShortcutDTO) -> Void, unsupported: @escaping () -> Void) { self.captured = captured; self.unsupported = unsupported }
        func flagsChanged(_ event: NSEvent) { deliver(decoder.flagsChanged(Self.modifiers(event))) }
        func keyDown(_ event: NSEvent) {
            deliver(decoder.keyDown(keyCode: event.keyCode, modifiers: Self.modifiers(event), isRepeat: event.isARepeat))
        }
        private func deliver(_ output: VoiceBindingCaptureDecoder.Output) {
            switch output {
            case .captured(let shortcut): captured(shortcut)
            case .unsupported: unsupported()
            case .ignored: break
            }
        }
        private static func modifiers(_ event: NSEvent) -> VoiceBindingCaptureDecoder.Modifiers {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var decoded: VoiceBindingCaptureDecoder.Modifiers = []
            if flags.contains(.control) { decoded.insert(.control) }
            if flags.contains(.option) { decoded.insert(.option) }
            if flags.contains(.shift) { decoded.insert(.shift) }
            if flags.contains(.command) { decoded.insert(.command) }
            // Some keyboards expose Globe/Fn only through the underlying CGEvent.
            // Both properties are public API; accept either representation.
            if flags.contains(.function) || event.cgEvent?.flags.contains(.maskSecondaryFn) == true {
                decoded.insert(.function)
            }
            return decoded
        }
    }
    final class CaptureView: NSView {
        var coordinator: Coordinator?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if let window { window.makeFirstResponder(self) } }
        override func keyDown(with event: NSEvent) { coordinator?.keyDown(event) }
        override func flagsChanged(with event: NSEvent) { coordinator?.flagsChanged(event) }
        override func cancelOperation(_ sender: Any?) {
            // Do not let the responder chain reinterpret Escape as capture cancellation.
        }
    }
}
