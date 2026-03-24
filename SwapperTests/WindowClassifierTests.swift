import XCTest

final class WindowClassifierTests: XCTestCase {
    func testFloatingAndDialogSubrolesAreExcludedFromDesktopRotation() {
        XCTAssertTrue(WindowClassifier.shouldExcludeFromDesktopRotation(subrole: "AXFloatingWindow"))
        XCTAssertTrue(WindowClassifier.shouldExcludeFromDesktopRotation(subrole: "AXSystemDialog"))
        XCTAssertTrue(WindowClassifier.shouldExcludeFromDesktopRotation(subrole: "AXSheet"))
    }

    func testUnknownOrMissingSubrolesRemainEligible() {
        XCTAssertFalse(WindowClassifier.shouldExcludeFromDesktopRotation(subrole: nil))
        XCTAssertFalse(WindowClassifier.shouldExcludeFromDesktopRotation(subrole: "AXStandardWindow"))
    }
}
