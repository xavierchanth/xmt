import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var voice = VoiceTranscriptionModule.shared

    var body: some View {
        switch voice.status {
        case .recording: Text("Voice: Recording…"); Button("Stop Recording") { voice.stopRecording() }
        case .finalizing: Text("Voice: Finalizing…")
        case .pending, .failed:
            Text("Voice: Recording needs attention")
            Button("Retry Recording") { voice.retryPending() }
            Button("Delete Recording", role: .destructive) { voice.deletePending() }
        case .degraded(let reason): Text("Voice: \(reason)")
        default: EmptyView()
        }
        if !voice.lastTranscript.isEmpty { Button("Copy Last Transcript") { voice.copyLastTranscript() } }
        Divider()
        Button("Settings...") { SettingsWindowController.shared.show { openWindow(id: SettingsWindowController.windowID) } }
            .keyboardShortcut(",", modifiers: .command)
        Divider()
        Button("Quit XMT") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
    }
}
