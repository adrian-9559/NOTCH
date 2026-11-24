import XCTest
@testable import NotchCore

final class AnnouncerTests: XCTestCase {
    func testDoneNeedsRealWork() {
        XCTAssertTrue(EpisodeJudge.shouldStartDoneClock(prev: .working, current: .done, worked: 25))
        XCTAssertFalse(EpisodeJudge.shouldStartDoneClock(prev: .working, current: .done, worked: 5))
    }

    func testDoneOnlyFromActivity() {
        XCTAssertFalse(EpisodeJudge.shouldStartDoneClock(prev: .idle, current: .done, worked: 99))
        XCTAssertFalse(EpisodeJudge.shouldStartDoneClock(prev: .done, current: .done, worked: 99))
        XCTAssertFalse(EpisodeJudge.shouldStartDoneClock(prev: nil, current: .done, worked: 99))
        XCTAssertFalse(EpisodeJudge.shouldStartDoneClock(prev: .working, current: .working, worked: 99))
    }

    func testSameRequestSuppression() {
        XCTAssertTrue(EpisodeJudge.shouldToastDone(stillDone: true, sameRequestNotified: false))
        // El subagente termina pero la petición sigue: no re-avisar.
        XCTAssertFalse(EpisodeJudge.shouldToastDone(stillDone: true, sameRequestNotified: true))
        XCTAssertFalse(EpisodeJudge.shouldToastDone(stillDone: false, sameRequestNotified: false))
    }

    func testWaitFiresOncePerEpisode() {
        XCTAssertTrue(EpisodeJudge.shouldStartWaitClock(prev: .working, current: .waiting))
        XCTAssertTrue(EpisodeJudge.shouldStartWaitClock(prev: nil, current: .waiting))
        // Mismo episodio esperando: no re-dispara.
        XCTAssertFalse(EpisodeJudge.shouldStartWaitClock(prev: .waiting, current: .waiting))
        XCTAssertFalse(EpisodeJudge.shouldStartWaitClock(prev: .waiting, current: .done))
    }

    func testQuestionLineExtractsTheQuestion() {
        struct Stub: AgentDetector {
            var agent: AgentID { .pi }
            var processHints: [String] { [] }
            var sessionPaths: [String] { [] }
        }
        let raw = "do stuff\nDo you approve running tests? [y/n]\nmore"
        let idx = raw.range(of: "[y/n]")!.lowerBound
        XCTAssertEqual(
            Stub.questionLine(around: idx, in: raw),
            "Do you approve running tests? [y/n]"
        )
    }

    func testQuestionLineRejectsBinary() {
        struct Stub: AgentDetector {
            var agent: AgentID { .pi }
            var processHints: [String] { [] }
            var sessionPaths: [String] { [] }
        }
        let raw = "SQLite\u{0}format\u{3}do you approve?\u{0}\u{1}\u{2}"
        let idx = raw.range(of: "approve")!.lowerBound
        XCTAssertNil(Stub.questionLine(around: idx, in: raw))
    }

    func testWaitingCarriesQuestionLine() {
        struct Stub: AgentDetector {
            var agent: AgentID { .pi }
            var processHints: [String] { ["__notch_fake_agent__"] }
            var sessionPaths: [String] { ["/tmp/__notch_wait_test__.log"] }
        }
        try? "log line\nShould I proceed with the deploy? confirm [y/n]\n"
            .write(toFile: "/tmp/__notch_wait_test__.log", atomically: true, encoding: .utf8)
        let snap = SystemSnapshot(tuples: [("/usr/bin/__notch_fake_agent__ --serve", 999, 1.0)])
        let s = MonitorEngine(detectors: [Stub()]).poll(snapshot: snap).first
        XCTAssertEqual(s?.status, .waiting)
        XCTAssertTrue(s?.detail?.contains("Should I proceed with the deploy?") ?? false)
        try? FileManager.default.removeItem(atPath: "/tmp/__notch_wait_test__.log")
    }
}
