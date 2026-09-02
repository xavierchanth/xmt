import AppKit
import ApplicationServices
import Carbon
import Foundation

@MainActor protocol PasteServicing { func paste(text: String, targetPID: pid_t?) async throws }

enum PasteError: Error { case accessibilityNotTrusted, noTargetApplication, secureInputActive, keyboardLayoutUnavailable, eventCreationFailed }

/// One-shot output action for the retained transcript. It intentionally has no dependency on
/// recording state, auto-paste settings, transcript commit, or recovery storage.
struct LatestTranscriptPaster {
    enum Outcome: Equatable {
        case pasted
        case noTranscript
        case noTarget
        case clipboardFailed
        case pasteFailed
    }

    struct Dependencies {
        var frontmostPID: () -> pid_t?
        var setClipboard: (String) throws -> Void
        var paste: (String, pid_t?) async throws -> Void

        @MainActor static var live: Dependencies {
            let board = NSPasteboard.general, service = PasteService()
            return .init(
                frontmostPID: { PasteService.frontmostPID() },
                setClipboard: {
                    board.clearContents()
                    guard board.setString($0, forType: .string) else { throw CocoaError(.fileWriteUnknown) }
                },
                paste: { try await service.paste(text: $0, targetPID: $1) }
            )
        }
    }

    var dependencies: Dependencies

    init(dependencies: Dependencies) { self.dependencies = dependencies }
    @MainActor init() { dependencies = .live }

    @MainActor func pasteLatest(_ transcript: String) async -> Outcome {
        let target = dependencies.frontmostPID()
        return await pasteLatest(transcript, targetPID: target)
    }

    @MainActor func pasteLatest(_ transcript: String, targetPID target: pid_t?) async -> Outcome {
        guard !transcript.isEmpty else { return .noTranscript }
        do { try dependencies.setClipboard(transcript) }
        catch { return .clipboardFailed }
        guard let target else { return .noTarget }
        do {
            try await dependencies.paste(transcript, target)
            return .pasted
        } catch {
            // The transcript deliberately remains on the clipboard for manual paste.
            return .pasteFailed
        }
    }
}

/// Posts logical Command-V only; it never mutates AX values or restores/wipes the clipboard after
/// posting. Consequently the completed transcript remains useful even when paste delivery fails.
struct PasteService: PasteServicing {
    static func frontmostPID(excluding ownPID: pid_t = ProcessInfo.processInfo.processIdentifier) -> pid_t? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ownPID else { return nil }
        return app.processIdentifier
    }

    @MainActor func paste(text: String, targetPID: pid_t?) async throws {
        guard AXIsProcessTrusted() else { throw PasteError.accessibilityNotTrusted }
        guard let pid = targetPID else { throw PasteError.noTargetApplication }
        guard !IsSecureEventInputEnabled() else { throw PasteError.secureInputActive }
        guard let keyCode = Self.logicalVKeyCode() else { throw PasteError.keyboardLayoutUnavailable }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { throw PasteError.eventCreationFailed }
        down.flags = .maskCommand; up.flags = .maskCommand; down.postToPid(pid); up.postToPid(pid)
    }

    /// Resolves the physical key producing an unmodified logical "v" in the current layout.
    private static func logicalVKeyCode() -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        for code in UInt16(0)..<128 {
            var deadKey: UInt32 = 0, length = 0, chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), 0,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &deadKey, chars.count, &length, &chars)
            if status == noErr, length == 1, chars[0] == 0x76 { return CGKeyCode(code) }
        }
        return nil
    }
}
