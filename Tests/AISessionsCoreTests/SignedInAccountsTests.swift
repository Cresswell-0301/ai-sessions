import XCTest
@testable import AISessionsCore

/// Whose usage alerts these are: the Claude account the sessions are signed
/// into (from `.claude.json`, never a token), and the alert scope built on it.
final class SignedInAccountsTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("signed-in-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private var defaultDir: URL { home.appendingPathComponent(".claude") }

    /// A `.claude.json` as Claude Code writes it: a lot of other state, and
    /// the account under `oauthAccount` (nil: signed out).
    private func write(_ email: String?, to url: URL) throws {
        var root: [String: Any] = ["numStartups": 41, "projects": ["/x": ["allowedTools": []]], "userID": "abc"]
        if let email { root["oauthAccount"] = ["emailAddress": email, "accountUuid": UUID().uuidString, "organizationName": "Org"] }
        try write(try JSONSerialization.data(withJSONObject: root), to: url)
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func testTheDefaultDirIsSignedInThroughTheFileBesideIt() throws {
        let accounts = SignedInAccounts(configDirs: [defaultDir], home: home)
        XCTAssertNil(accounts.emails(), "no file yet: not known, which is not 'nobody'")
        try write("Cresswell.Nexxatech@gmail.com", to: home.appendingPathComponent(".claude.json"))
        XCTAssertEqual(accounts.emails(), ["cresswell.nexxatech@gmail.com"], "lower-cased, as matched")
    }

    func testAProfileDirKeepsItsOwnFile() throws {
        let profile = home.appendingPathComponent("profiles/trimo")
        try write("trimo@example.com", to: profile.appendingPathComponent(".claude.json"))
        try write("default@example.com", to: home.appendingPathComponent(".claude.json"))
        XCTAssertEqual(SignedInAccounts(configDirs: [profile], home: home).emails(), ["trimo@example.com"],
                       "~/.claude.json belongs to the default dir only")
        XCTAssertEqual(SignedInAccounts(configDirs: [profile, defaultDir], home: home).emails(),
                       ["trimo@example.com", "default@example.com"])
    }

    func testASwitchIsSeenAndAHalfWrittenFileChangesNothing() throws {
        let file = home.appendingPathComponent(".claude.json")
        let accounts = SignedInAccounts(configDirs: [defaultDir], home: home)
        try write("a@example.com", to: file)
        XCTAssertEqual(accounts.emails(), ["a@example.com"])
        try write(Data(#"{"numStartups": 41, "oauthAcc"#.utf8), to: file)
        XCTAssertEqual(accounts.emails(), ["a@example.com"], "caught mid-write: the last answer stands")
        try write("b@example.com", to: file)
        XCTAssertEqual(accounts.emails(), ["b@example.com"], "signed in to another account")
        try write(nil, to: file)
        XCTAssertNil(accounts.emails(), "no account in the file (a login saves it so for a moment): not known")
        try FileManager.default.removeItem(at: file)
        XCTAssertNil(accounts.emails(), "no file: not known")
    }

    func testAFileThatNamesNobodyGivesWayToOneThatDoes() throws {
        // A stray ~/.claude/.claude.json without an account, beside the real one.
        try write(nil, to: defaultDir.appendingPathComponent(".claude.json"))
        try write("real@example.com", to: home.appendingPathComponent(".claude.json"))
        let accounts = SignedInAccounts(configDirs: [defaultDir], home: home)
        XCTAssertEqual(accounts.emails(), ["real@example.com"])
        XCTAssertEqual(accounts.emails(), ["real@example.com"], "and again from the cache")
    }

    // MARK: The scope

    func testTheAlertScope() {
        let claudeTrimo = UsageAccount(tool: "claude", label: "trimo", windows: [], email: "TrimoMalaysia@gmail.com")
        let codexTrimo = UsageAccount(tool: "codex", label: "trimomalaysia", windows: [], email: "trimomalaysia@gmail.com")
        let core = UsageAccount(tool: "claude", label: "CoreOS", windows: [], email: "nexxacoreos@gmail.com")
        let signedIn: Set<String> = ["trimomalaysia@gmail.com"]

        let current = UsageAlertScope(["current"])
        XCTAssertTrue(current.needsSignedIn)
        XCTAssertTrue(current.covers(claudeTrimo, signedIn: signedIn))
        XCTAssertFalse(current.covers(codexTrimo, signedIn: signedIn), "the same address on Codex is another account")
        XCTAssertFalse(current.covers(core, signedIn: signedIn))
        XCTAssertFalse(current.covers(claudeTrimo, signedIn: nil), "nobody known: nobody covered")

        let all = UsageAlertScope(["ALL"])
        XCTAssertFalse(all.needsSignedIn)
        XCTAssertTrue(all.covers(core, signedIn: nil))

        let mixed = UsageAlertScope([" current ", "codex:TrimoMalaysia", "coreos", ""])
        XCTAssertTrue(mixed.covers(codexTrimo, signedIn: []), "tool and label")
        XCTAssertTrue(mixed.covers(core, signedIn: []), "a label, any case")
        XCTAssertFalse(mixed.covers(claudeTrimo, signedIn: []), "named for Codex only")

        let byEmail = UsageAlertScope(["NexxaCoreOS@gmail.com"])
        XCTAssertFalse(byEmail.needsSignedIn)
        XCTAssertTrue(byEmail.covers(core, signedIn: nil))
        XCTAssertFalse(UsageAlertScope([]).covers(core, signedIn: ["nexxacoreos@gmail.com"]), "an empty list covers nobody")
    }

    func testTheDashboardRowsCarryTheirEmail() throws {
        let data = try JSONSerialization.data(withJSONObject: ["rows": [
            ["tool": "claude", "label": "trimo", "email": "trimomalaysia@gmail.com", "skipped": "signed in — no usage recorded yet",
             "limits": ["error": NSNull(), "windows": [["kind": "weekly_all", "label": "Weekly (7 day)", "pct": 40, "resets": NSNull()]]]],
            ["tool": "codex", "label": "x", "email": NSNull(), "limits": ["windows": [["kind": "weekly", "pct": 3]]]],
        ]])
        let snapshot = try XCTUnwrap(UsageSnapshot.parse(data, fetchedAt: Date()))
        XCTAssertEqual(snapshot.accounts.map(\.email), ["trimomalaysia@gmail.com", nil])
        XCTAssertEqual(snapshot.accounts.map(\.key), ["claude|trimo", "codex|x"])
        XCTAssertEqual(snapshot.only { $0.tool == "codex" }.accounts.map(\.label), ["x"])
    }

    func testTheSettingReadsAListOrOneWord() throws {
        func decode(_ json: String) throws -> [String] {
            try JSONDecoder().decode(Config.self, from: Data(json.utf8)).usageAlertAccounts
        }
        XCTAssertEqual(try decode("{}"), ["current"], "the account in use, by default")
        XCTAssertEqual(try decode(#"{"usageAlertAccounts": ["current", "codex:nexxaflo"]}"#), ["current", "codex:nexxaflo"])
        XCTAssertEqual(try decode(#"{"usageAlertAccounts": "all"}"#), ["all"])
        XCTAssertEqual(try decode(#"{"usageAlertAccounts": 7}"#), ["current"], "nonsense keeps the default")
    }
}
