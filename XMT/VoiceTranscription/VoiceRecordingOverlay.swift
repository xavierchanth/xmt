import AppKit
import SwiftUI

struct VoiceOverlayPresentation: Equatable {
    enum Phase: Equatable { case hidden, arming, recording, finalizing }
    var phase: Phase
    var partialTranscript: String
    var outputMode: VoiceOutputMode
    var showsElapsed: Bool { phase == .recording }
    var isVisible: Bool { phase != .hidden }
}

@MainActor
final class VoiceRecordingOverlayController: ObservableObject {
    static let shared = VoiceRecordingOverlayController()
    @Published private(set) var presentation = VoiceOverlayPresentation(phase: .hidden, partialTranscript: "", outputMode: .pasteImmediately)
    @Published private(set) var elapsed: TimeInterval = 0
    private var panel: NSPanel?
    private var timer: Timer?
    private var startedAt: Date?
    private var isPresented = false

    func update(_ value: VoiceOverlayPresentation) {
        presentation = value
        if value.isVisible { if !isPresented { show(); isPresented = true } } else { hide(); isPresented = false }
        if value.showsElapsed { startElapsedIfNeeded() } else { stopElapsed() }
    }

    private func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(.init(x: frame.midX - panel.frame.width / 2, y: frame.minY + 44))
        }
        panel.orderFrontRegardless()
    }
    private func hide() { panel?.orderOut(nil); stopElapsed() }
    private func startElapsedIfNeeded() {
        guard timer == nil else { return }
        startedAt = Date(); elapsed = 0
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { guard let self, let startedAt = self.startedAt else { return }; self.elapsed = Date().timeIntervalSince(startedAt) } }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func stopElapsed() { timer?.invalidate(); timer = nil; startedAt = nil; elapsed = 0 }
    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .init(x: 0, y: 0, width: 390, height: 132), styleMask: [.nonactivatingPanel, .hudWindow], backing: .buffered, defer: true)
        panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false; panel.isMovableByWindowBackground = true
        panel.setAccessibilityLabel("Voice recording controls")
        panel.contentView = NSHostingView(rootView: VoiceRecordingOverlayView(controller: self))
        return panel
    }
}

private struct VoiceRecordingOverlayView: View {
    @ObservedObject var controller: VoiceRecordingOverlayController
    private var phase: String {
        switch controller.presentation.phase { case .hidden: return ""; case .arming: return "Preparing…"; case .recording: return "Recording"; case .finalizing: return "Finalizing…" }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(phase).font(.headline); Spacer(); if controller.presentation.showsElapsed { Text(Duration.seconds(controller.elapsed).formatted(.time(pattern: .minuteSecond))) } }
            Text(controller.presentation.partialTranscript.isEmpty ? "Listening for speech…" : controller.presentation.partialTranscript).lineLimit(2).accessibilityLabel("Partial transcript")
            HStack {
                Text(controller.presentation.outputMode == .pasteImmediately ? "Clipboard, then paste" : "Clipboard only").foregroundStyle(.secondary)
                Spacer()
                if controller.presentation.phase == .recording {
                    Button("Stop") { VoiceTranscriptionModule.shared.stopRecording() }.accessibilityHint("Finish and publish this recording")
                    Button("Cancel", role: .cancel) { VoiceTranscriptionModule.shared.cancelVoiceInteraction() }.accessibilityHint("Discard this recording without output")
                } else if controller.presentation.phase == .arming {
                    Button("Cancel", role: .cancel) { VoiceTranscriptionModule.shared.cancelVoiceInteraction() }.accessibilityHint("Cancel before recording starts")
                }
            }
        }.padding(14).frame(width: 390, height: 132).accessibilityElement(children: .contain)
    }
}
