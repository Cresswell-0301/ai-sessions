import XCTest

/// The bundle's Info.plist and the LaunchAgent template the scripts install:
/// the keys DESIGN.md and the install flow depend on.
final class AppPackagingTests: XCTestCase {
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func plist(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.packageRoot.appendingPathComponent(path))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testInfoPlistDescribesAMenuBarOnlyApp() throws {
        let info = try plist("Resources/Info.plist")

        XCTAssertEqual(info["CFBundleIdentifier"] as? String, "local.ai-sessions.menubar")
        XCTAssertEqual(info["CFBundleName"] as? String, "AI Sessions")
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "AI Sessions")
        XCTAssertEqual(info["CFBundleExecutable"] as? String, "AISessions")
        XCTAssertEqual(info["CFBundlePackageType"] as? String, "APPL")
        XCTAssertEqual(info["CFBundleShortVersionString"] as? String, "1.0.0")
        XCTAssertEqual(info["CFBundleVersion"] as? String, "1")
        XCTAssertEqual(info["LSUIElement"] as? Bool, true, "no Dock icon, no app menu")
        XCTAssertEqual(info["LSMinimumSystemVersion"] as? String, "14.0")
        XCTAssertEqual(info["CFBundleIconFile"] as? String, "AppIcon")
        XCTAssertEqual(info["NSHighResolutionCapable"] as? Bool, true)
    }

    func testTheLaunchAgentRestartsTheAppOnlyAfterACrash() throws {
        let agent = try plist("deploy/local.ai-sessions.menubar.plist")

        XCTAssertEqual(agent["Label"] as? String, "local.ai-sessions.menubar")
        XCTAssertEqual(agent["ProgramArguments"] as? [String],
                       ["__HOME__/Applications/AISessions.app/Contents/MacOS/AISessions"])
        XCTAssertEqual(agent["RunAtLoad"] as? Bool, true)
        XCTAssertEqual((agent["KeepAlive"] as? [String: Any])?["SuccessfulExit"] as? Bool, false,
                       "Quit exits 0 and must stay quit")
        XCTAssertEqual(agent["ThrottleInterval"] as? Int, 10)
        XCTAssertEqual(agent["ProcessType"] as? String, "Interactive")
        XCTAssertEqual(agent["LimitLoadToSessionType"] as? String, "Aqua")
        XCTAssertEqual(agent["StandardOutPath"] as? String, "__HOME__/.ai-sessions/state/launchd.log")
        XCTAssertEqual(agent["StandardErrorPath"] as? String, "__HOME__/.ai-sessions/state/launchd.log")
    }

    func testTheScriptsAreExecutable() {
        for script in ["build.sh", "install.sh", "uninstall.sh"] {
            let path = Self.packageRoot.appendingPathComponent("scripts/\(script)").path
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path), path)
        }
    }
}
