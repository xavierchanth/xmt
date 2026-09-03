import AppKit
import Combine
import OSLog

/// Owns XMT's single status item and native menu for the lifetime of the application delegate.
/// Updates are driven by published module state and menu-open events; there is no idle timer.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let logger = Logger(subsystem: "com.xavierchanth.xmt", category: "MenuBar")
    private let voice = VoiceTranscriptionModule.shared
    private let history = TranscriptHistoryViewModel.shared
    private let windowMover = WindowMoverModule.shared
    private let statusItem: NSStatusItem
    private var cancellables: Set<AnyCancellable> = []

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        configureButton()
        observeState()
        rebuildMenu()
    }

    private func configureButton() {
        guard let button = statusItem.button else {
            logger.fault("The status item has no button")
            return
        }
        button.image = statusImage()
        button.imagePosition = .imageOnly
        button.toolTip = "XMT — window movement and voice transcription"
        button.setAccessibilityLabel("XMT menu")
    }

    private func statusImage() -> NSImage {
        if let asset = NSImage(named: "MenuBarIcon"), Self.containsVisiblePixel(asset) {
            asset.isTemplate = true
            return asset
        }
        logger.error("MenuBarIcon is missing or transparent; using the system fallback glyph")
        if let fallback = NSImage(systemSymbolName: "arrow.left.arrow.right.circle.fill",
                                  accessibilityDescription: "XMT") {
            fallback.isTemplate = true
            return fallback
        }
        // Symbols are present on every supported macOS, but retain a drawing fallback so the
        // status item can never become a clickable blank if asset/symbol loading regresses.
        let fallback = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.labelColor.setStroke()
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
            path.lineWidth = 2
            path.stroke()
            return true
        }
        fallback.isTemplate = true
        return fallback
    }

    static func containsVisiblePixel(_ image: NSImage) -> Bool {
        guard image.isValid, image.size.width > 0, image.size.height > 0,
              let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) else { return false }
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.02 {
                return true
            }
        }
        return false
    }

    private func observeState() {
        [voice.objectWillChange.eraseToAnyPublisher(), history.objectWillChange.eraseToAnyPublisher(),
         windowMover.objectWillChange.eraseToAnyPublisher()].forEach { publisher in
            publisher.receive(on: RunLoop.main).sink { [weak self] _ in
                // Published values are assigned after objectWillChange; rebuild on the next turn.
                DispatchQueue.main.async { self?.rebuildMenu() }
            }.store(in: &cancellables)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
        guard history.isHistoryEnabled else { return }
        Task { await history.reload(limit: TranscriptHistorySnapshot.menuPreviewCount) }
    }

    private func rebuildMenu() {
        let menu = NSMenu(title: "XMT")
        menu.delegate = self
        addWindowMoverItems(to: menu)
        menu.addItem(.separator())
        addVoiceItems(to: menu)
        menu.addItem(.separator())
        addHistoryItems(to: menu)
        menu.addItem(.separator())
        menu.addItem(item("Settings…", action: #selector(showSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("Quit XMT", action: #selector(quit), key: "q"))
        statusItem.menu = menu
    }

    private func addWindowMoverItems(to menu: NSMenu) {
        let status = item("Window Mover: \(windowMover.isEnabled ? "Enabled" : "Disabled")",
                          action: #selector(toggleWindowMover))
        status.state = windowMover.isEnabled ? .on : .off
        status.isEnabled = !windowMover.isEnabledManaged
        menu.addItem(status)
    }

    private func addVoiceItems(to menu: NSMenu) {
        let startingCount = menu.items.count
        switch voice.status {
        case .recording:
            menu.addItem(label("Voice: Recording…")); menu.addItem(item("Stop Recording", action: #selector(stopRecording)))
        case .finalizing: menu.addItem(label("Voice: Finalizing…"))
        case .pending:
            menu.addItem(label("Voice: Recording needs attention"))
            menu.addItem(item("Retry Recording", action: #selector(retryPending)))
            menu.addItem(item("Delete Recording", action: #selector(deletePending)))
        case .failed(let reason): menu.addItem(label("Voice failed: \(reason)"))
        case .degraded(let reason): menu.addItem(label("Voice: \(reason)"))
        default: break
        }
        if let feedback = voice.temporaryFeedback { menu.addItem(label("Voice: \(feedback)")) }
        if !voice.lastTranscript.isEmpty { menu.addItem(item("Copy Last Transcript", action: #selector(copyLastTranscript))) }
        if menu.items.count == startingCount { menu.addItem(label("Voice: Ready")) }
    }

    private func addHistoryItems(to menu: NSMenu) {
        guard history.isHistoryEnabled else { menu.addItem(label("Transcript history is off")); return }
        let root = NSMenuItem(title: "Recent Transcripts", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Recent Transcripts")
        if history.hasEntries {
            for preview in history.recentPreviews {
                let row = item(preview.title, action: #selector(copyHistory(_:)))
                row.representedObject = preview.id
                submenu.addItem(row)
            }
            submenu.addItem(.separator())
            submenu.addItem(item("Copy Latest Transcript", action: #selector(copyLatest)))
        } else { submenu.addItem(label("No transcripts yet")) }
        root.submenu = submenu
        menu.addItem(root)
        menu.addItem(item("Show All Transcripts…", action: #selector(showHistory)))
        if history.isClearConfirmationPending {
            menu.addItem(item("Confirm Clear History", action: #selector(confirmClear)))
            menu.addItem(item("Cancel Clearing History", action: #selector(cancelClear)))
        } else if history.hasEntries { menu.addItem(item("Clear History…", action: #selector(requestClear))) }
    }

    private func item(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let result = NSMenuItem(title: title, action: action, keyEquivalent: key)
        result.target = self
        return result
    }

    private func label(_ title: String) -> NSMenuItem {
        let result = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        result.isEnabled = false
        return result
    }

    @objc private func toggleWindowMover() { windowMover.setEnabled(!windowMover.isEnabled) }
    @objc private func stopRecording() { voice.stopRecording() }
    @objc private func retryPending() { voice.retryPending() }
    @objc private func deletePending() { voice.deletePending() }
    @objc private func copyLastTranscript() { voice.copyLastTranscript() }
    @objc private func copyHistory(_ sender: NSMenuItem) { if let id = sender.representedObject as? UUID { history.copy(id: id) } }
    @objc private func copyLatest() { history.copyLatest() }
    @objc private func showHistory() { TranscriptHistoryPanelController.shared.show() }
    @objc private func requestClear() { history.requestClear() }
    @objc private func cancelClear() { history.cancelClear() }
    @objc private func confirmClear() { Task { await history.confirmClear() } }
    @objc private func showSettings() { SettingsWindowController.shared.show() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
