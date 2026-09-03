import AppKit
import KeyboardShortcuts
import SwiftUI

/// XMT-owned capture UI. Escape alone cancels; modified Escape is captured.
struct VoiceBindingRecorder: View {
    let title: String
    let action: VoiceBindingAction
    let value: ShortcutDTO
    let isManaged: Bool
    let isRecording: Bool
    let begin: () -> Void
    let cancel: () -> Void
    let commit: (ShortcutDTO) async -> String?

    @State private var diagnostic: String?
    @State private var isCommitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            LabeledContent(title) {
                HStack {
                    Text(Self.display(value)).monospacedDigit().accessibilityLabel("Current binding: \(Self.display(value))")
                    if isRecording {
                        KeyDownCaptureView(captured: { captured($0) }, cancelled: cancel, unsupported: {
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
                            .accessibilityHint("Capture the next key down, including Escape")
                        Button("Clear") { submit(.unbound) }
                            .accessibilityHint("Unbind this action")
                    }
                }
            }
            if let diagnostic { Text(diagnostic).font(.caption).foregroundStyle(.red).accessibilityLabel("Binding error: \(diagnostic)") }
        }
        .disabled(isManaged || isCommitting)
    }

    private func captured(_ shortcut: ShortcutDTO) { submit(shortcut) }
    private func submit(_ shortcut: ShortcutDTO) {
        isCommitting = true
        Task { @MainActor in
            diagnostic = await commit(shortcut)
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
    let cancelled: () -> Void
    let unsupported: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(captured: captured, cancelled: cancelled, unsupported: unsupported) }
    func makeNSView(context: Context) -> CaptureView { let view = CaptureView(); view.coordinator = context.coordinator; return view }
    func updateNSView(_ view: CaptureView, context: Context) { view.coordinator = context.coordinator }
    final class Coordinator {
        let captured: (ShortcutDTO) -> Void; let cancelled: () -> Void; let unsupported: () -> Void
        var sawFnDown = false
        init(captured: @escaping (ShortcutDTO) -> Void, cancelled: @escaping () -> Void, unsupported: @escaping () -> Void) { self.captured = captured; self.cancelled = cancelled; self.unsupported = unsupported }
        func flagsChanged(_ event: NSEvent) {
            let down = event.modifierFlags.contains(.function)
            if down { sawFnDown = true }
            else if sawFnDown { sawFnDown = false; captured(.modifierHold("fn")) }
        }
        func keyDown(_ event: NSEvent) {
            guard !event.isARepeat, let key = ShortcutDTO.keyName(forKeyCode: event.keyCode) else { if !event.isARepeat { unsupported() }; return }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.function) { sawFnDown = false; captured(.fnChord(key: key)); return }
            let names: [(NSEvent.ModifierFlags, String)] = [(.control,"control"),(.option,"option"),(.shift,"shift"),(.command,"command")]
            let modifiers = names.compactMap { flags.contains($0.0) ? $0.1 : nil }
            if key == "escape" && modifiers.isEmpty { cancelled(); return }
            captured(.key(key: key, modifiers: modifiers))
        }
    }
    final class CaptureView: NSView {
        var coordinator: Coordinator?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if let window { window.makeFirstResponder(self) } }
        override func keyDown(with event: NSEvent) { coordinator?.keyDown(event) }
        override func flagsChanged(with event: NSEvent) { coordinator?.flagsChanged(event) }
    }
}
