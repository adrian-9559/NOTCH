import XCTest
@testable import NotchCore

final class JunkPathsTests: XCTestCase {
    func testRejectsSystemPaths() {
        XCTAssertEqual(JunkPaths.expand("/etc/passwd"), [])
        XCTAssertEqual(JunkPaths.expand("/System/Library/CoreServices/Finder.app"), [])
    }

    func testRejectsTraversalOutOfTmp() {
        // ".." se resuelve y el resultado (/etc/passwd) queda fuera.
        XCTAssertEqual(JunkPaths.expand("/tmp/../../etc/passwd"), [])
    }

    func testAllowsHomePaths() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let hits = JunkPaths.expand("\(home)/.claude/sessions")
        XCTAssertEqual(hits.count, 1)
        XCTAssertTrue(hits[0].contains(".claude/sessions"))
        // El home exacto jamás (borraría todo).
        XCTAssertEqual(JunkPaths.expand(home), [])
    }

    func testGlobExpandsOnlyInTmp() throws {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: d) }
        try "x".write(to: d.appendingPathComponent("metro-a.log"), atomically: true, encoding: .utf8)
        try "y".write(to: d.appendingPathComponent("other.log"), atomically: true, encoding: .utf8)

        let hits = JunkPaths.expand(d.path + "/metro-*.log")
        XCTAssertEqual(hits.count, 1)
        XCTAssertTrue(hits[0].hasSuffix("metro-a.log"))

        // Globs fuera de la zona temporal: prohibidos.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(JunkPaths.expand(home + "/*.log"), [])
    }

    func testTmpSiblingPrefixRejected() {
        // /private/tmpEVIL NO pasa por prefijo de /private/tmp.
        XCTAssertEqual(JunkPaths.expand("/private/tmpEVIL/x", tmpRoot: "/private/tmp"), [])
        // ...pero /private/tmp/sí (si existe el fichero: no lo comprobamos
        // aquí, solo que el filtro de prefijos no lo descarta).
        let hits = JunkPaths.expand("/private/tmp/__notch_no_such_file__",
                                    tmpRoot: "/private/tmp")
        XCTAssertEqual(hits, ["/private/tmp/__notch_no_such_file__"])
    }
}
