import XCTest

/// Verification and paste-outcome coverage only. No test touches Accessibility, TCC, the pasteboard,
/// or a real process: every process fact and every paste attempt is injected.
final class CapturedPasteTargetTests: XCTestCase {
    private let captured = Date(timeIntervalSince1970: 1_700_000_000)

    private func verifier(
        running: Bool = true,
        bundleIdentifier: String? = "com.example.editor",
        ownPID: pid_t = 1,
        now: TimeInterval = 10,
        maximumAge: TimeInterval = 300
    ) -> CapturedTargetVerifier {
        CapturedTargetVerifier(maximumAge: maximumAge, dependencies: .init(
            isRunning: { _ in running },
            bundleIdentifier: { _ in bundleIdentifier },
            ownPID: { ownPID },
            now: { self.captured.addingTimeInterval(now) }))
    }

    private func target(pid: pid_t = 42, bundleIdentifier: String? = "com.example.editor") -> CapturedPasteTarget {
        CapturedPasteTarget(pid: pid, bundleIdentifier: bundleIdentifier, localizedName: "Editor", capturedAt: captured)
    }

    func testValidTargetResolvesToTheCapturedProcess() {
        XCTAssertEqual(verifier().verify(target()), .valid(42))
    }

    func testMissingTerminatedAndSelfTargetsAreRejected() {
        XCTAssertEqual(verifier().verify(nil), .rejected(.noCapturedTarget))
        XCTAssertEqual(verifier(running: false).verify(target()), .rejected(.terminated))
        XCTAssertEqual(verifier(ownPID: 42).verify(target(pid: 42)), .rejected(.isSelf))
    }

    func testReusedPidWithDifferentIdentityIsRejected() {
        XCTAssertEqual(verifier(bundleIdentifier: "com.example.other").verify(target()), .rejected(.identityChanged))
    }

    func testTargetsWithoutBundleIdentityAreAcceptedWhenStillRunning() {
        XCTAssertEqual(verifier(bundleIdentifier: nil).verify(target(bundleIdentifier: nil)), .valid(42))
    }

    func testStaleCaptureIsRejectedBeforeAnyProcessLookup() {
        var lookups = 0
        let verifier = CapturedTargetVerifier(maximumAge: 60, dependencies: .init(
            isRunning: { _ in lookups += 1; return true },
            bundleIdentifier: { _ in lookups += 1; return "com.example.editor" },
            ownPID: { 1 },
            now: { self.captured.addingTimeInterval(61) }))
        XCTAssertEqual(verifier.verify(target()), .rejected(.expired))
        XCTAssertEqual(lookups, 0)
    }

    func testPasteCopiesBeforeVerifyingAndPosting() async {
        var events: [String] = []
        let paster = CapturedTargetPaster(dependencies: .init(
            setClipboard: { events.append("clipboard:\($0)") },
            verify: { _ in events.append("verify"); return .valid(7) },
            paste: { text, pid in events.append("paste:\(text):\(pid)") }))
        let outcome = await paster.paste("hello", to: target())
        XCTAssertEqual(outcome, .pasted(7))
        XCTAssertEqual(events, ["clipboard:hello", "verify", "paste:hello:7"])
    }

    func testRejectedTargetStillLeavesTranscriptOnClipboardAndPostsNothing() async {
        var clipboard = "old"
        var posted = false
        let paster = CapturedTargetPaster(dependencies: .init(
            setClipboard: { clipboard = $0 },
            verify: { _ in .rejected(.terminated) },
            paste: { _, _ in posted = true }))
        let outcome = await paster.paste("survives", to: target())
        XCTAssertEqual(outcome, .copiedOnly(.terminated))
        XCTAssertEqual(clipboard, "survives")
        XCTAssertFalse(posted)
    }

    func testPasteFailurePreservesClipboardContents() async {
        enum Expected: Error { case paste }
        var clipboard = "old"
        let paster = CapturedTargetPaster(dependencies: .init(
            setClipboard: { clipboard = $0 },
            verify: { _ in .valid(9) },
            paste: { _, _ in throw Expected.paste }))
        let outcome = await paster.paste("kept", to: target())
        XCTAssertEqual(outcome, .pasteFailed)
        XCTAssertEqual(clipboard, "kept")
    }

    func testClipboardFailureStopsBeforeVerificationAndPaste() async {
        enum Expected: Error { case clipboard }
        var verified = false, posted = false
        let paster = CapturedTargetPaster(dependencies: .init(
            setClipboard: { _ in throw Expected.clipboard },
            verify: { _ in verified = true; return .valid(9) },
            paste: { _, _ in posted = true }))
        let outcome = await paster.paste("text", to: target())
        XCTAssertEqual(outcome, .clipboardFailed)
        XCTAssertFalse(verified)
        XCTAssertFalse(posted)
    }

    func testBlankTextIsNeverCopiedOrPasted() async {
        var touched = false
        let paster = CapturedTargetPaster(dependencies: .init(
            setClipboard: { _ in touched = true },
            verify: { _ in .valid(9) },
            paste: { _, _ in touched = true }))
        let outcome = await paster.paste("   \n ", to: target())
        XCTAssertEqual(outcome, .noText)
        XCTAssertFalse(touched)
    }
}
