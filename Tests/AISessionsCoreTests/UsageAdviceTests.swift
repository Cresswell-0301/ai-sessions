import XCTest
@testable import AISessionsCore

/// "Use first" must be the dashboard's own pick. Every case in
/// Fixtures/use-first-cases.json was run through the dashboard page's script
/// (recommend / pickChip, verbatim, clock pinned): its answers are the
/// expected values here, the chip's exact words included.
final class UsageAdviceTests: XCTestCase {
    private struct Case {
        let name: String
        let now: Date
        let snapshot: UsageSnapshot
        let excluded: Set<String>
        let expect: [String: Any]
    }

    private func cases() throws -> [Case] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/use-first-cases.json")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let raw = try XCTUnwrap(root["cases"] as? [[String: Any]])
        return try raw.map { item in
            let name = try XCTUnwrap(item["name"] as? String)
            let now = Date(timeIntervalSince1970: try XCTUnwrap(item["now"] as? NSNumber).doubleValue)
            let rows = try JSONSerialization.data(withJSONObject: ["rows": item["rows"] ?? []])
            return Case(name: name, now: now, snapshot: try XCTUnwrap(UsageSnapshot.parse(rows, fetchedAt: now), name),
                        excluded: Set(item["excluded"] as? [String] ?? []), expect: item["expect"] as? [String: Any] ?? [:])
        }
    }

    func testThePickIsTheDashboardsOwnInEveryCase() throws {
        let all = try cases()
        XCTAssertEqual(all.count, 34)
        var compared = 0
        for c in all {
            for (tool, expected) in c.expect {
                let pick = UsageAdvice.useFirst(c.snapshot.accounts, tool: tool, excluded: c.excluded, now: c.now)
                let where_ = "\(c.name) [\(tool)]"
                compared += 1
                guard let expected = expected as? [String: Any] else {
                    XCTAssertNil(pick, "\(where_): the page shows no pick")
                    continue
                }
                XCTAssertEqual(pick?.account.label, expected["label"] as? String, where_)
                XCTAssertEqual(pick?.mode.rawValue, expected["mode"] as? String, where_)
                XCTAssertEqual(pick?.used, (expected["used"] as? NSNumber)?.intValue, where_)
                XCTAssertEqual(pick?.left, (expected["left"] as? NSNumber)?.intValue, where_)
                XCTAssertEqual(pick?.chip, expected["chip"] as? String, where_)
            }
        }
        XCTAssertEqual(compared, 36, "every case and every tool in it was compared")
    }

    func testTheExclusionKeyAndFile() throws {
        let withEmail = UsageAccount(tool: "claude", label: "trimo", windows: [], email: "TrimoMalaysia@gmail.com")
        let without = UsageAccount(tool: "codex", label: "slot9", windows: [])
        XCTAssertEqual(UsageAdvice.exclusionKey(withEmail), "claude:TrimoMalaysia@gmail.com", "as the page writes it, case kept")
        XCTAssertEqual(UsageAdvice.exclusionKey(without), "codex:slot9")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("exclude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(".suggest-exclude.json")
        XCTAssertEqual(SuggestExclusions.load(from: file), [], "no file: nothing excluded")
        try Data(#"["claude:finance.nexxa@gmail.com", "claude:trimomalaysia@gmail.com"]"#.utf8).write(to: file)
        XCTAssertEqual(SuggestExclusions.load(from: file), ["claude:finance.nexxa@gmail.com", "claude:trimomalaysia@gmail.com"])
        try Data(#"["claude:fin"#.utf8).write(to: file)
        XCTAssertEqual(SuggestExclusions.load(from: file), [], "caught mid-write: nothing excluded, as the dashboard reads it")
    }
}
