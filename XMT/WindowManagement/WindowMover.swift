import AppKit
import ApplicationServices

enum WindowMover {
    /// Moves the currently focused window to the next monitor.
    /// - Preserves relative position and scale on the new screen.
    /// - If the window is full-screen: exits FS, moves, re-enters FS.
    /// - If the window is minimized: silently skips.
    @MainActor
    static func moveFocusedWindowToNextScreen() async {
        guard AccessibilityService.shared.isGranted else {
            AccessibilityReminder.showIfNeeded()
            return
        }

        let screens = NSScreen.screens
        guard screens.count > 1 else { return }

        guard let windowInfo = AXWindowInfo.focusedWindow() else { return }
        guard !windowInfo.isMinimized else { return }

        guard let axOrigin = windowInfo.position,
              let axSize = windowInfo.size else { return }

        let currentFrame = ScreenCoordinates.nsWindowFrame(axOrigin: axOrigin, axSize: axSize)

        guard let currentScreen = ScreenCoordinates.screenContaining(nsFrame: currentFrame) else { return }

        guard let currentIndex = screens.firstIndex(of: currentScreen) else { return }
        let nextIndex = (currentIndex + 1) % screens.count
        let targetScreen = screens[nextIndex]

        let wasFullScreen = windowInfo.isFullScreen

        if wasFullScreen {
            guard await windowInfo.exitFullScreen() else { return }
            try? await Task.sleep(for: .milliseconds(200))
            apply(frame: WindowGeometry.fillFrame(targetScreen.frame), to: windowInfo)

            try? await Task.sleep(for: .milliseconds(300))
            let reenteredFullScreen = await windowInfo.enterFullScreen()
            if !reenteredFullScreen {
                apply(frame: WindowGeometry.fillFrame(targetScreen.frame), to: windowInfo)
            }
            return
        }

        let requestedFrame = targetFrame(
            for: currentFrame,
            from: currentScreen.frame,
            to: targetScreen.frame
        )
        apply(frame: requestedFrame, to: windowInfo)
        reconcileFrame(for: windowInfo, requestedFrame: requestedFrame, targetScreenFrame: targetScreen.frame)
    }

    private static func targetFrame(
        for currentFrame: CGRect,
        from sourceScreenFrame: CGRect,
        to targetScreenFrame: CGRect
    ) -> CGRect {
        if WindowGeometry.isWithinVisibleFrame(currentFrame, visibleFrame: sourceScreenFrame) {
            return WindowGeometry.proportionalFrame(
                for: currentFrame,
                from: sourceScreenFrame,
                to: targetScreenFrame
            )
        }

        return WindowGeometry.fillFrame(targetScreenFrame)
    }

    private static func apply(frame: CGRect, to windowInfo: AXWindowInfo) {
        windowInfo.position = ScreenCoordinates.axOrigin(forNSWindowFrame: frame)
        windowInfo.size = frame.size
    }

    private static func reconcileFrame(
        for windowInfo: AXWindowInfo,
        requestedFrame: CGRect,
        targetScreenFrame: CGRect
    ) {
        guard let currentRealizedFrame = realizedFrame(for: windowInfo) else { return }

        let correctedFrame = WindowGeometry.correctedFrame(
            requestedFrame: requestedFrame,
            realizedSize: currentRealizedFrame.size,
            in: targetScreenFrame
        )

        if correctedFrame.origin != currentRealizedFrame.origin {
            windowInfo.position = ScreenCoordinates.axOrigin(forNSWindowFrame: correctedFrame)
        }

        if needsSizeRetry(realizedSize: currentRealizedFrame.size, requestedSize: requestedFrame.size) {
            windowInfo.size = requestedFrame.size

            guard let retriedFrame = realizedFrame(for: windowInfo) else { return }
            let retriedCorrectedFrame = WindowGeometry.correctedFrame(
                requestedFrame: requestedFrame,
                realizedSize: retriedFrame.size,
                in: targetScreenFrame
            )

            if retriedCorrectedFrame.origin != retriedFrame.origin {
                windowInfo.position = ScreenCoordinates.axOrigin(forNSWindowFrame: retriedCorrectedFrame)
            }
        }
    }

    private static func realizedFrame(for windowInfo: AXWindowInfo) -> CGRect? {
        guard let realizedOrigin = windowInfo.position,
              let realizedSize = windowInfo.size else { return nil }

        return ScreenCoordinates.nsWindowFrame(axOrigin: realizedOrigin, axSize: realizedSize)
    }

    private static func needsSizeRetry(realizedSize: CGSize, requestedSize: CGSize) -> Bool {
        abs(realizedSize.width - requestedSize.width) > 1 || abs(realizedSize.height - requestedSize.height) > 1
    }
}
