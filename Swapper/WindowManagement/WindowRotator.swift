import AppKit
import ApplicationServices

enum WindowRotator {
    /// Rotates all windows across all monitors:
    /// windows on screen[0] → screen[1], screen[1] → screen[2], …, screen[N-1] → screen[0].
    /// - Preserves relative position and scale.
    /// - Skips minimized windows.
    /// - For full-screen windows: exits FS, moves, re-enters FS.
    @MainActor
    static func rotateDesktops() async {
        guard AccessibilityService.isGranted else {
            AccessibilityReminder.showIfNeeded()
            return
        }

        let screens = NSScreen.screens
        guard screens.count > 1 else { return }

        struct WindowMove {
            let windowInfo: AXWindowInfo
            let currentFrame: CGRect
            let fromScreen: NSScreen
            let toScreen: NSScreen
        }

        var moves: [WindowMove] = []

        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular || $0.activationPolicy == .accessory
        }

        for app in runningApps {
            let windows = AXWindowInfo.allWindows(for: app.processIdentifier)
            for window in windows {
                guard !window.isMinimized else { continue }
                guard !window.isFullScreen else { continue }
                guard !WindowClassifier.shouldExcludeFromDesktopRotation(subrole: window.subrole) else {
                    continue
                }
                guard let axOrigin = window.position,
                      let axSize = window.size else { continue }

                let currentFrame = ScreenCoordinates.nsWindowFrame(axOrigin: axOrigin, axSize: axSize)

                guard let fromScreen = ScreenCoordinates.screenContaining(nsFrame: currentFrame) else { continue }

                guard let fromIndex = screens.firstIndex(of: fromScreen) else { continue }
                let toIndex = (fromIndex + 1) % screens.count
                let toScreen = screens[toIndex]

                moves.append(WindowMove(
                    windowInfo: window,
                    currentFrame: currentFrame,
                    fromScreen: fromScreen,
                    toScreen: toScreen
                ))
            }
        }

        guard !moves.isEmpty else { return }

        for move in moves {
            let requestedFrame = targetFrame(
                for: move.currentFrame,
                from: move.fromScreen.frame,
                to: move.toScreen.frame
            )
            apply(frame: requestedFrame, to: move.windowInfo)
            reconcileFrame(
                for: move.windowInfo,
                requestedFrame: requestedFrame,
                targetFrame: move.toScreen.frame
            )
        }
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
        targetFrame: CGRect
    ) {
        guard let currentRealizedFrame = realizedFrame(for: windowInfo) else { return }
        let correctedFrame = WindowGeometry.correctedFrame(
            requestedFrame: requestedFrame,
            realizedSize: currentRealizedFrame.size,
            in: targetFrame
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
                in: targetFrame
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
