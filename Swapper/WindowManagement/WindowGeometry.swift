import CoreGraphics

enum WindowGeometry {
    static let offScreenTolerance: CGFloat = 16

    enum HorizontalAnchor {
        case left
        case right
        case center
    }

    enum VerticalAnchor {
        case top
        case bottom
        case center
    }

    struct Anchors: Equatable {
        let horizontal: HorizontalAnchor
        let vertical: VerticalAnchor
    }

    static func proportionalFrame(
        for windowFrame: CGRect,
        from sourceVisibleFrame: CGRect,
        to destinationVisibleFrame: CGRect
    ) -> CGRect {
        let relLeft = sourceVisibleFrame.width > 0
            ? (windowFrame.minX - sourceVisibleFrame.minX) / sourceVisibleFrame.width
            : 0
        let relTop = sourceVisibleFrame.height > 0
            ? (sourceVisibleFrame.maxY - windowFrame.maxY) / sourceVisibleFrame.height
            : 0
        let relWidth = sourceVisibleFrame.width > 0 ? windowFrame.width / sourceVisibleFrame.width : 1
        let relHeight = sourceVisibleFrame.height > 0 ? windowFrame.height / sourceVisibleFrame.height : 1

        let width = destinationVisibleFrame.width * relWidth
        let height = destinationVisibleFrame.height * relHeight
        let minX = destinationVisibleFrame.minX + destinationVisibleFrame.width * relLeft
        let maxY = destinationVisibleFrame.maxY - destinationVisibleFrame.height * relTop

        return CGRect(x: minX, y: maxY - height, width: width, height: height)
    }

    static func fillFrame(_ frame: CGRect) -> CGRect {
        frame
    }

    static func isWithinVisibleFrame(
        _ windowFrame: CGRect,
        visibleFrame: CGRect,
        tolerance: CGFloat = offScreenTolerance
    ) -> Bool {
        let toleranceInsets = UIEdgeInsets(
            top: -tolerance,
            left: -tolerance,
            bottom: -tolerance,
            right: -tolerance
        )
        return visibleFrame.inset(by: toleranceInsets).contains(windowFrame)
    }

    static func anchors(for requestedFrame: CGRect, in visibleFrame: CGRect) -> Anchors {
        let leftDistance = abs(requestedFrame.minX - visibleFrame.minX)
        let rightDistance = abs(visibleFrame.maxX - requestedFrame.maxX)
        let bottomDistance = abs(requestedFrame.minY - visibleFrame.minY)
        let topDistance = abs(visibleFrame.maxY - requestedFrame.maxY)

        let horizontal: HorizontalAnchor
        if leftDistance == rightDistance {
            horizontal = .center
        } else {
            horizontal = leftDistance < rightDistance ? .left : .right
        }

        let vertical: VerticalAnchor
        if topDistance == bottomDistance {
            vertical = .center
        } else {
            vertical = topDistance < bottomDistance ? .top : .bottom
        }

        return Anchors(horizontal: horizontal, vertical: vertical)
    }

    static func correctedFrame(
        requestedFrame: CGRect,
        realizedSize: CGSize,
        in visibleFrame: CGRect
    ) -> CGRect {
        let anchors = anchors(for: requestedFrame, in: visibleFrame)

        let minX: CGFloat
        switch anchors.horizontal {
        case .left:
            minX = requestedFrame.minX
        case .right:
            minX = requestedFrame.maxX - realizedSize.width
        case .center:
            minX = requestedFrame.midX - (realizedSize.width / 2)
        }

        let minY: CGFloat
        switch anchors.vertical {
        case .bottom:
            minY = requestedFrame.minY
        case .top:
            minY = requestedFrame.maxY - realizedSize.height
        case .center:
            minY = requestedFrame.midY - (realizedSize.height / 2)
        }

        return CGRect(origin: CGPoint(x: minX, y: minY), size: realizedSize)
    }
}

private struct UIEdgeInsets {
    let top: CGFloat
    let left: CGFloat
    let bottom: CGFloat
    let right: CGFloat
}

private extension CGRect {
    func inset(by insets: UIEdgeInsets) -> CGRect {
        CGRect(
            x: origin.x + insets.left,
            y: origin.y + insets.bottom,
            width: width - insets.left - insets.right,
            height: height - insets.top - insets.bottom
        )
    }
}
