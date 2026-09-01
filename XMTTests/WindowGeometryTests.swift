import CoreGraphics
import XCTest

final class WindowGeometryTests: XCTestCase {
    func testAXCoordinateFlipUsesPrimaryTopNotDesktopUnion() {
        // An external display may sit above the primary and push the desktop union to y=1800.
        // AX coordinates still flip around the primary display's top at y=900.
        let frame = CGRect(x: 120, y: 1050, width: 500, height: 300)
        let ax = ScreenCoordinates.axOrigin(forNSWindowFrame: frame, flipReferenceY: 900)
        XCTAssertEqual(ax.x, 120, accuracy: 0.001)
        XCTAssertEqual(ax.y, -450, accuracy: 0.001)
        XCTAssertEqual(
            ScreenCoordinates.nsWindowFrame(axOrigin: ax, axSize: frame.size, flipReferenceY: 900),
            frame
        )
    }

    func testAXCoordinateRoundTripAcrossNegativeDesktopCoordinates() {
        let frame = CGRect(x: -1440, y: -700, width: 800, height: 600)
        let origin = ScreenCoordinates.axOrigin(forNSWindowFrame: frame, flipReferenceY: 900)
        XCTAssertEqual(
            ScreenCoordinates.nsWindowFrame(axOrigin: origin, axSize: frame.size, flipReferenceY: 900),
            frame
        )
    }

    func testProportionalFrameUsesTopLeftAnchoringAndVisibleFrames() {
        let sourceVisibleFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let destinationVisibleFrame = CGRect(x: 1000, y: 0, width: 1500, height: 900)
        let windowFrame = CGRect(x: 100, y: 300, width: 400, height: 200)

        let projected = WindowGeometry.proportionalFrame(
            for: windowFrame,
            from: sourceVisibleFrame,
            to: destinationVisibleFrame
        )

        XCTAssertEqual(projected.origin.x, 1150, accuracy: 0.001)
        XCTAssertEqual(projected.origin.y, 337.5, accuracy: 0.001)
        XCTAssertEqual(projected.width, 600, accuracy: 0.001)
        XCTAssertEqual(projected.height, 225, accuracy: 0.001)
    }

    func testPartiallyOffScreenDetectionHonorsSixteenPointTolerance() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let withinTolerance = CGRect(x: -8, y: 0, width: 500, height: 400)
        let outsideTolerance = CGRect(x: -20, y: 0, width: 500, height: 400)

        XCTAssertTrue(WindowGeometry.isWithinVisibleFrame(withinTolerance, visibleFrame: visibleFrame))
        XCTAssertFalse(WindowGeometry.isWithinVisibleFrame(outsideTolerance, visibleFrame: visibleFrame))
    }

    func testFillFrameReturnsDestinationFrame() {
        let destinationFrame = CGRect(x: 1440, y: 0, width: 1440, height: 900)

        XCTAssertEqual(
            WindowGeometry.fillFrame(destinationFrame),
            destinationFrame
        )
    }

    func testCorrectedFramePreservesRightAndBottomEdges() {
        let visibleFrame = CGRect(x: 1000, y: 0, width: 1200, height: 900)
        let requestedFrame = CGRect(x: 1700, y: 200, width: 300, height: 400)
        let realizedSize = CGSize(width: 360, height: 500)

        let corrected = WindowGeometry.correctedFrame(
            requestedFrame: requestedFrame,
            realizedSize: realizedSize,
            in: visibleFrame
        )

        XCTAssertEqual(corrected.origin.x, 1640, accuracy: 0.001)
        XCTAssertEqual(corrected.origin.y, 200, accuracy: 0.001)
        XCTAssertEqual(corrected.size.width, realizedSize.width, accuracy: 0.001)
        XCTAssertEqual(corrected.size.height, realizedSize.height, accuracy: 0.001)
    }

    func testCorrectedFrameCentersTiedAxes() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let requestedFrame = CGRect(x: 300, y: 250, width: 400, height: 300)
        let realizedSize = CGSize(width: 500, height: 200)

        let corrected = WindowGeometry.correctedFrame(
            requestedFrame: requestedFrame,
            realizedSize: realizedSize,
            in: visibleFrame
        )

        XCTAssertEqual(corrected.origin.x, 250, accuracy: 0.001)
        XCTAssertEqual(corrected.origin.y, 300, accuracy: 0.001)
    }
}
