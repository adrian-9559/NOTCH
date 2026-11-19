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
}
