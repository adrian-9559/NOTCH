import XCTest
@testable import NotchCore

final class DetectorTests: XCTestCase {
    func testAllSixteenRegistered() {
        XCTAssertEqual(AllDetectors.all.count, 16)
        XCTAssertEqual(Set(AllDetectors.all.map(\.agent)).count, 16)
    }

    func testNoFalsePositiveWhenIdle() {
        struct StubDetector: AgentDetector {
            var agent: AgentID { .pi }
            var processHints: [String] { ["__nonexistent_proc_12345__"] }
            var sessionPaths: [String] { ["/tmp/__notch_no_such_dir_12345__"] }
        }
        let snap = SystemSnapshot(tuples: [("sbin/launchd", 1, 0.1)])
        let engine = MonitorEngine(detectors: [StubDetector()])
        XCTAssertTrue(engine.poll(snapshot: snap).isEmpty)
    }

    func testOpencodeDetectedWhenProcessRuns() {
        // Simula lo visto en este Mac: proceso `opencode` vivo.
        let snap = SystemSnapshot(tuples: [("opencode serve --service", 22552, 5.5)])
        let sessions = MonitorEngine().poll(snapshot: snap)
        XCTAssertTrue(sessions.contains { $0.agent == .opencode })
        XCTAssertEqual(sessions.first { $0.agent == .opencode }?.status, .working)
    }

    func testCodexDetectedWhenProcessRuns() {
        let snap = SystemSnapshot(tuples: [("codex app-server --analytics-default-enabled", 27869, 0.5)])
        let sessions = MonitorEngine().poll(snapshot: snap)
        XCTAssertTrue(sessions.contains { $0.agent == .codex })
    }

    func testNeedsAttentionFiltersWaiting() {
        let engine = MonitorEngine()
        let list = [
            AgentSession(agent: .claudeCode, sessionID: "a", status: .working),
            AgentSession(agent: .codex, sessionID: "b", status: .waiting),
        ]
        XCTAssertEqual(engine.needsAttention(list).map(\.agent), [.codex])
    }

    func testParsePsWithCommaDecimalLocale() {
        // macOS en es_ES imprime "5,5" en %CPU: el parser debe aceptarlo.
        let snap = ProcessMonitor.parsePsOutput("22552  5,5 opencode serve --service\n27869  0,5 codex app-server\n")
        XCTAssertEqual(snap.processes.count, 2)
        XCTAssertEqual(snap.processes[0].cpu, 5.5, accuracy: 0.001)
        XCTAssertTrue(snap.processes[0].command.contains("opencode"))
    }

    // MARK: - Casos límite de detección (auditoría de noviembre)

    func testPiDetectedByExactBasename() {
        // `/usr/local/bin/pi` sin espacios: solo el basename exacto lo
        // coge (los contains " pi " / "/pi " se colaban con "pip").
        struct D: AgentDetector {
            var agent: AgentID { .pi }
            var processHints: [String] { [" pi ", "/pi ", "pi-mono", "picode"] }
            var processBasenames: [String] { ["pi", "picode"] }
            var sessionPaths: [String] { ["/tmp/__notch_no_such_dir_pi__"] }
        }
        let run = SystemSnapshot(tuples: [("/usr/local/bin/pi --prompt x", 501, 2.0)])
        XCTAssertEqual(MonitorEngine(detectors: [D()]).poll(snapshot: run).first?.agent, .pi)

        let pip = SystemSnapshot(tuples: [("/usr/bin/pip install requests", 502, 2.0)])
        XCTAssertTrue(MonitorEngine(detectors: [D()]).poll(snapshot: pip).isEmpty)
    }

    func testClineExtensionNotClaimedByClaude() {
        // El id de la extensión de Cline contiene "claude-dev": Claude
        // lo excluye y Cline lo reclama.
        struct D: AgentDetector {
            var agent: AgentID
            var processHints: [String]
            var processExclusions: [String] = []
            var sessionPaths: [String] { ["/tmp/__notch_no_such_dir_x__"] }
        }
        let ext = SystemSnapshot(tuples: [("/Code.app helper saoudrizwan.claude-dev", 503, 8.0)])
        let claude = D(agent: .claudeCode, processHints: ["claude"], processExclusions: ["saoudrizwan"])
        XCTAssertTrue(MonitorEngine(detectors: [claude]).poll(snapshot: ext).isEmpty)
        let cline = D(agent: .cline, processHints: ["cline", "saoudrizwan", "claude-dev"])
        XCTAssertEqual(MonitorEngine(detectors: [cline]).poll(snapshot: ext).first?.agent, .cline)
    }

    func testFreshLogFileMeansWorkingWithoutProcess() throws {
        // Agente solo-por-fichero (extensión): el log que se escribe
        // AHORA cuenta como en uso, no como "crashed".
        struct FileDetector: AgentDetector {
            var agent: AgentID { .geminiCLI }
            var processHints: [String] { ["__nonexistent_proc__"] }
            var sessionPaths: [String]
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-test-\(UUID().uuidString).log")
        try "hola".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let d = FileDetector(sessionPaths: [url.path])
        let fresh = MonitorEngine(detectors: [d]).poll(snapshot: SystemSnapshot(tuples: []))
        XCTAssertEqual(fresh.first?.status, .working)

        // Cinco minutos viejo: murió (crashed).
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-300)],
            ofItemAtPath: url.path)
        let stale = MonitorEngine(detectors: [d]).poll(snapshot: SystemSnapshot(tuples: []))
        XCTAssertEqual(stale.first?.status, .crashed)
    }

    func testWaitingFromFreshFilesWithoutProcess() throws {
        // Pregunta en el log fresco también vale como waiting aunque el
        // proceso del host no matchee ningún hint.
        struct FileDetector: AgentDetector {
            var agent: AgentID { .cline }
            var processHints: [String] { ["__nonexistent_proc__"] }
            var sessionPaths: [String]
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-test-\(UUID().uuidString).log")
        try "linea previa\nDo you want to continue? needs your approval (y/n)\n"
            .write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let d = FileDetector(sessionPaths: [url.path])
        let s = MonitorEngine(detectors: [d]).poll(snapshot: SystemSnapshot(tuples: []))
        XCTAssertEqual(s.first?.status, .waiting)
    }

    func testUnmappedAgentsReportsOnlyUnknownBrands() {
        // "aider" no está en los16 → se reporta para la auditoría.
        let unknown = SystemSnapshot(tuples: [("aider --model x", 9, 1.0)])
        XCTAssertTrue(ProcessMonitor.unmappedAgents(in: unknown).contains { $0.hasPrefix("aider:") })
        // "code … saoudrizwan.claude-dev" lo reclama Cline → NO se reporta.
        let claimed = SystemSnapshot(tuples: [("Code helper saoudrizwan.claude-dev", 10, 1.0)])
        XCTAssertTrue(ProcessMonitor.unmappedAgents(in: claimed).isEmpty)
        // Nada de marcas → nada que reportar.
        let plain = SystemSnapshot(tuples: [("node server.js", 11, 1.0)])
        XCTAssertTrue(ProcessMonitor.unmappedAgents(in: plain).isEmpty)
    }
}
