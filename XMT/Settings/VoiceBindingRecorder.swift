import AppKit
import KeyboardShortcuts
import SwiftUI

/// XMT-owned capture UI. Escape is data; editing ends only through the explicit Cancel control.
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
    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView(); view.handler = context.coordinator.handle; return view
    }
    func updateNSView(_ view: CaptureView, context: Context) { view.handler = context.coordinator.handle }
    final class Coordinator {
        let captured: (ShortcutDTO) -> Void
        let unsupported: () -> Void
        init(captured: @escaping (ShortcutDTO) -> Void, unsupported: @escaping () -> Void) { self.captured = captured; self.unsupported = unsupported }
        func handle(_ event: NSEvent) {
            guard !event.isARepeat else { return }
            guard let shortcut = KeyboardShortcuts.Shortcut(event: event), let dto = ShortcutDTO.fromKeyboardShortcut(shortcut) else {
                unsupported(); return
            }
            captured(dto)
        }
    }
    final class CaptureView: NSView {
        var handler: ((NSEvent) -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { window.makeFirstResponder(self) }
        }
        override func keyDown(with event: NSEvent) { handler?(event) }
    }
}
