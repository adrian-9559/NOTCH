import XCTest
@testable import NotchCore

final class NotchGeometryTests: XCTestCase {
    func testDetectsPhysicalNotch() {
        // Pantalla 1440x900, áreas auxiliares a cada lado del notch.
        let frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let left = CGRect(x: 0, y: 870, width: 620, height: 30)
        let right = CGRect(x: 820, y: 870, width: 620, height: 30)
        let lay = NotchLayout.make(screenFrame: frame, leftArea: left, rightArea: right, menuThickness: 24)
        XCTAssertTrue(lay.hasNotch)
        XCTAssertEqual(lay.notchRect.minX, 620, accuracy: 0.5)
        XCTAssertEqual(lay.notchRect.width, 200, accuracy: 0.5)
    }

    func testNoNotchWithoutAreas() {
        let frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertFalse(NotchLayout.make(screenFrame: frame, leftArea: nil, rightArea: nil, menuThickness: 24).hasNotch)
        let zero = CGRect.zero
        XCTAssertFalse(NotchLayout.make(screenFrame: frame, leftArea: zero, rightArea: zero, menuThickness: 24).hasNotch)
    }

    func testVirtualNotchIsCentered() {
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let v = NotchLayout.virtualNotch(screenFrame: frame, menuThickness: 24)
        XCTAssertEqual(v.midX, frame.midX, accuracy: 0.5)
        XCTAssertEqual(v.width, 180, accuracy: 0.5)
    }
}
