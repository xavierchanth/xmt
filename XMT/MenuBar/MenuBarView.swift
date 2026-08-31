import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var voice = VoiceTranscriptionModule.shared
    @ObservedObject private var history = TranscriptHistoryViewModel.shared

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
        if let feedback = voice.temporaryFeedback { Text("Voice: \(feedback)") }
        if !voice.lastTranscript.isEmpty { Button("Copy Last Transcript") { voice.copyLastTranscript() } }
        // History is read when the menu opens, never on a timer.
        Divider().task { await history.reload() }
        if history.hasEntries {
            Text("Recent Transcripts")
            ForEach(history.recentPreviews) { preview in
                Button(preview.title) { history.copy(id: preview.id) }
            }
            Button("Copy Latest Transcript") { history.copyLatest() }
        } else {
            Text("No transcripts yet")
        }
        Button("Show All Transcripts...") { TranscriptHistoryPanelController.shared.show() }
        if history.isClearConfirmationPending {
            Button("Confirm Clear History", role: .destructive) { Task { await history.confirmClear() } }
            Button("Cancel Clearing History") { history.cancelClear() }
        } else if history.hasEntries {
            Button("Clear History...") { history.requestClear() }
        }
        Divider()
        Button("Settings...") { SettingsWindowController.shared.show { openWindow(id: SettingsWindowController.windowID) } }
            .keyboardShortcut(",", modifiers: .command)
        Divider()
        Button("Quit XMT") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
    }
}
