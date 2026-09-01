import AppKit
import SwiftUI

/// Lazily creates the transcript history panel. Nothing is built, loaded, or observed until the
/// user asks to see all transcripts; closing the panel releases it again, so no window, view, or
/// captured target is retained while the panel is not on screen.
@MainActor
final class TranscriptHistoryPanelController: NSObject, NSWindowDelegate {
    static let shared = TranscriptHistoryPanelController()

    private let viewModel: TranscriptHistoryViewModel
    private var panel: NSPanel?

    override convenience init() {
        self.init(viewModel: .shared)
    }

    init(viewModel: TranscriptHistoryViewModel) {
        self.viewModel = viewModel
        super.init()
    }

    var isPresented: Bool { panel != nil }

    /// Presents the panel. When history is effectively disabled this is inert: no window is built,
    /// no paste target is captured, and no history is read, so the store is never opened or created.
    func show() {
        guard viewModel.isHistoryEnabled else { return }
        // Capture the paste destination before XMT takes key focus.
        viewModel.captureTarget()
        Task { await viewModel.loadIfNeeded() }

        if let panel {
            present(panel)
            return
        }

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 460),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "Transcript History"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: TranscriptHistoryPanelView(viewModel: viewModel)
            .frame(minWidth: 360, minHeight: 320))
        panel.center()
        self.panel = panel
        present(panel)
    }

    func close() { panel?.close() }

    private func present(_ panel: NSPanel) {
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        panel?.delegate = nil
        panel?.contentView = nil
        panel = nil
        viewModel.releaseTarget()
        viewModel.searchQuery = ""
        viewModel.completeSnapshotNoLongerNeeded()
    }
}
