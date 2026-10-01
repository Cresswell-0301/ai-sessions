import XCTest
@testable import AISessionsCore

final class ModelTests: XCTestCase {
    func testSessionKeyRoundTrip() {
        let key = SessionKey(agent: .claude, id: "9eb4895f-b5d9-41d0-8161-864ac0eecf46")
        XCTAssertEqual(SessionKey(string: key.description), key)
        XCTAssertNil(SessionKey(string: "nope"))
        XCTAssertNil(SessionKey(string: "claude:"))
    }

    func testProcStartParsesAsctimeUTC() {
        let d = ProcessKit.parseProcStart("Thu Oct  1 02:59:07 2026")
        XCTAssertNotNil(d)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d!)
        XCTAssertEqual([c.year, c.month, c.day, c.hour, c.minute, c.second], [2026, 10, 1, 2, 59, 7])
    }

    func testOwnProcessMatchesItsStartTime() {
        let pid = getpid()
        XCTAssertTrue(ProcessKit.isAlive(pid))
        let info = ProcessKit.info(pid)
        XCTAssertNotNil(info)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        XCTAssertTrue(ProcessKit.matchesProcStart(pid, procStart: f.string(from: info!.startTime)))
        XCTAssertFalse(ProcessKit.matchesProcStart(pid, procStart: "Mon Jan  1 00:00:00 2001"))
    }

    func testFormatting() {
        XCTAssertEqual(Formatting.duration(8), "8s")
        XCTAssertEqual(Formatting.duration(4 * 60 + 2), "4m")
        XCTAssertEqual(Formatting.duration(65 * 60), "1h 05m")
        XCTAssertEqual(Formatting.project(for: "/Users/nexflo/coreOS"), "coreOS")
        XCTAssertEqual(Formatting.project(for: "/Users/nexflo/coreOS/.claude/worktrees/inventory"), "coreOS/inventory")
        XCTAssertEqual(Formatting.oneLine("a\n  b   c", max: 80), "a b c")
        XCTAssertEqual(Formatting.oneLine("abcdefghij", max: 5), "abcd…")
    }

    func testConfigDefaultsAndPartialJSON() throws {
        let partial = #"{"minTurnSecondsToNotify": 30, "unknownKey": 1}"#.data(using: .utf8)!
        let c = try JSONDecoder().decode(Config.self, from: partial)
        XCTAssertEqual(c.minTurnSecondsToNotify, 30)
        XCTAssertEqual(c.claudeConfigDirs, ["~/.claude"])
        XCTAssertTrue(c.notificationsEnabled)
    }
}
