import AppKit
import KeyboardShortcuts
import SwiftUI

/// XMT-owned capture UI. Escape is data; editing ends only through the explicit Cancel control.
struct VoiceBindingRecorder: View {
    let title: String
    let action: VoiceBindingAction
    let value: ShortcutDTO
    let isManaged: Bool
    let commit: (ShortcutDTO) -> String?

    @State private var isRecording = false
    @State private var diagnostic: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            LabeledContent(title) {
                HStack {
                    Text(Self.display(value)).monospacedDigit().accessibilityLabel("Current binding: \(Self.display(value))")
                    if isRecording {
                        KeyDownCaptureView { shortcut in
                            var model = VoiceBindingRecorderModel(); model.receive(.begin); model.receive(.captured(shortcut))
                            diagnostic = commit(model.committed ?? shortcut)
                            if diagnostic == nil { isRecording = false }
                        }
                        .frame(width: 1, height: 1)
                        Text("Press a key chord…").foregroundStyle(.secondary)
                        Button("Cancel") { var model = VoiceBindingRecorderModel(); model.receive(.begin); model.receive(.cancel); isRecording = false }
                            .accessibilityHint("Stop editing without changing the binding")
                    } else {
                        if action == .holdToTalk {
                            Button("Fn") { diagnostic = commit(.modifierHold("fn")) }
                                .accessibilityHint("Use the Function modifier by itself")
                        }
                        Button("Record") { diagnostic = nil; isRecording = true }
                            .accessibilityHint("Capture the next key down, including Escape")
                        Button("Clear") { diagnostic = commit(.unbound) }
                            .accessibilityHint("Unbind this action")
                    }
                }
            }
            if let diagnostic { Text(diagnostic).font(.caption).foregroundStyle(.red).accessibilityLabel("Binding error: \(diagnostic)") }
        }
        .disabled(isManaged)
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
    func makeCoordinator() -> Coordinator { Coordinator(captured) }
    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView(); view.handler = context.coordinator.handle
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }
    func updateNSView(_ view: CaptureView, context: Context) {
        view.handler = context.coordinator.handle
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }
    final class Coordinator {
        let captured: (ShortcutDTO) -> Void
        init(_ captured: @escaping (ShortcutDTO) -> Void) { self.captured = captured }
        func handle(_ event: NSEvent) {
            guard !event.isARepeat, let shortcut = KeyboardShortcuts.Shortcut(event: event),
                  let dto = ShortcutDTO.fromKeyboardShortcut(shortcut) else { return }
            captured(dto)
        }
    }
    final class CaptureView: NSView {
        var handler: ((NSEvent) -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) { handler?(event) }
    }
}
