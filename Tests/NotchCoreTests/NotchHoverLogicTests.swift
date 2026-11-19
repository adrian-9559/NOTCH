import XCTest
@testable import NotchCore

final class NotchHoverLogicTests: XCTestCase {
    func testClosedOpensOnNotch() {
        XCTAssertEqual(HoverLogic.decide(visible: false, inNotch: true, inPanel: false, armed: false, outsideElapsed: 0), .show)
        XCTAssertEqual(HoverLogic.decide(visible: false, inNotch: false, inPanel: false, armed: false, outsideElapsed: 9), .none)
    }

    func testOpenStaysWhileInside() {
        XCTAssertEqual(HoverLogic.decide(visible: true, inNotch: true, inPanel: false, armed: true, outsideElapsed: 9), .none)
        XCTAssertEqual(HoverLogic.decide(visible: true, inNotch: false, inPanel: true, armed: true, outsideElapsed: 9), .none)
    }

    func testOpenClosesAfterGraceOnlyIfArmed() {
        XCTAssertEqual(HoverLogic.decide(visible: true, inNotch: false, inPanel: false, armed: true, outsideElapsed: 0.5), .hide)
        XCTAssertEqual(HoverLogic.decide(visible: true, inNotch: false, inPanel: false, armed: true, outsideElapsed: 0.2), .none)
        // Abierto por menú con el ratón fuera: no se toca hasta entrar una vez.
        XCTAssertEqual(HoverLogic.decide(visible: true, inNotch: false, inPanel: false, armed: false, outsideElapsed: 9), .none)
    }
}
