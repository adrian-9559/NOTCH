import XCTest
@testable import NotchCore

/// El lanzador evalúa lo que el usuario escriba: NUNCA puede lanzar
/// excepciones (NSExpression tumbaba la app con «2++3»).
final class ArithTests: XCTestCase {
    func testSuma() { XCTAssertEqual(Arith.eval("2+2") ?? -1, 4) }
    func testPrecedenciaYParentesis() { XCTAssertEqual(Arith.eval("(1+2)*3") ?? -1, 9) }
    func testDivisionDecimales() { XCTAssertEqual(Arith.eval("7.5/2.5") ?? -1, 3) }
    func testBasuraDevuelveNilSinExplotar() {
        XCTAssertNil(Arith.eval("2++3"))
        XCTAssertNil(Arith.eval("2a+2a"))
        XCTAssertNil(Arith.eval("2+*3"))
        XCTAssertNil(Arith.eval("hola"))
    }
    func testDivisionPorCeroNil() { XCTAssertNil(Arith.eval("1/0")) }
    func testCasoLive() { XCTAssertEqual(Arith.eval("(10-4)*2") ?? -1, 12) }
    func testCharsetLive() {
        let q = "(10-4)*2"
        XCTAssertNotNil(q.range(of: "^[0-9+\\-*/(). ]+$", options: .regularExpression))
        XCTAssertNotNil(q.range(of: "[+\\-*/]", options: .regularExpression))
    }
    func testUnario() { XCTAssertEqual(Arith.eval("-5+2") ?? -99, -3) }
}
