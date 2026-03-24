import AppKit

/// Utilities for converting between AXUIElement coordinate space and NSScreen coordinate space.
///
/// AXUIElement (kAXPositionAttribute): origin = top-left of the virtual desktop, Y increases downward.
/// NSScreen.frame: origin = bottom-left of the primary screen, Y increases upward.
///
/// IMPORTANT: Use the top edge of the combined desktop bounds for Y flipping.
/// Using only the first screen's height breaks moves involving displays taller than the primary screen.
enum ScreenCoordinates {

    // MARK: - Coordinate Conversion

    /// Convert a point from AX coordinate space to NSScreen (AppKit) coordinate space.
    static func axPointToNS(_ axPoint: CGPoint) -> CGPoint {
        CGPoint(x: axPoint.x, y: desktopMaxY - axPoint.y)
    }

    /// Convert a point from NSScreen (AppKit) coordinate space to AX coordinate space.
    static func nsPointToAX(_ nsPoint: CGPoint) -> CGPoint {
        CGPoint(x: nsPoint.x, y: desktopMaxY - nsPoint.y)
    }

    /// The top-most Y value in the combined desktop coordinate space, used as the AX Y-flip reference.
    static var desktopMaxY: CGFloat {
        desktopFrame.maxY
    }

    static var desktopFrame: CGRect {
        let frames = NSScreen.screens.map(\.frame)
        guard let firstFrame = frames.first else { return .zero }

        return frames.dropFirst().reduce(firstFrame) { partialResult, frame in
            partialResult.union(frame)
        }
    }

    // MARK: - Screen Detection

    /// Given a window's position and size in AX coordinate space, return the NSScreen
    /// that contains the largest portion of the window.
    static func screenContaining(axOrigin: CGPoint, axSize: CGSize) -> NSScreen? {
        screenContaining(nsFrame: nsWindowFrame(axOrigin: axOrigin, axSize: axSize))
    }

    static func screenContaining(nsFrame: CGRect) -> NSScreen? {
        return NSScreen.screens.max { a, b in
            a.frame.intersection(nsFrame).area < b.frame.intersection(nsFrame).area
        }
    }

    static func nsWindowFrame(axOrigin: CGPoint, axSize: CGSize) -> CGRect {
        let nsTopLeft = axPointToNS(axOrigin)
        return CGRect(
            x: nsTopLeft.x,
            y: nsTopLeft.y - axSize.height,
            width: axSize.width,
            height: axSize.height
        )
    }

    static func axOrigin(forNSWindowFrame frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX, y: desktopMaxY - frame.maxY)
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}
