import AppKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject private var voice = VoiceTranscriptionModule.shared
    @ObservedObject private var history = TranscriptHistoryViewModel.shared

    var body: some View {
        Group {
        switch voice.status {
        case .recording: Text("Voice: Recording…"); Button("Stop Recording") { voice.stopRecording() }
        case .finalizing: Text("Voice: Finalizing…")
        case .pending:
            Text("Voice: Recording needs attention")
            Button("Retry Recording") { voice.retryPending() }
            Button("Delete Recording", role: .destructive) { voice.deletePending() }
        case .failed(let reason): Text("Voice failed: \(reason)")
        case .degraded(let reason): Text("Voice: \(reason)")
        default: EmptyView()
        }
        if let feedback = voice.temporaryFeedback { Text("Voice: \(feedback)") }
        if !voice.lastTranscript.isEmpty { Button("Copy Last Transcript") { voice.copyLastTranscript() } }
        // History is read when the menu root appears, never on a timer. The menu asks for only the
        // five rows it can render; the request is upgraded to a full read while the panel is open,
        // so refreshing the menu can never truncate the panel's list.
        Divider()
        if history.isHistoryEnabled {
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
        } else {
            // Disabled history shows one inert line: no previews, no panel entry point, and no
            // read, so the menu cannot open or create the database.
            Text("Transcript history is off")
        }
        Divider()
        Button("Settings...") { SettingsWindowController.shared.show() }
            .keyboardShortcut(",", modifiers: .command)
        Divider()
        Button("Quit XMT") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
        }
        .onAppear { Task { await history.reload(limit: TranscriptHistorySnapshot.menuPreviewCount) } }
    }
}
