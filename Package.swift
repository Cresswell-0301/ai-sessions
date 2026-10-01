// swift-tools-version:6.0
// AI Sessions — menu-bar tracker for Claude Code and Codex sessions.
// Build:   scripts/build.sh      (release .app bundle in build/)
// Install: scripts/install.sh    (~/Applications + LaunchAgent)
import PackageDescription

let package = Package(
    name: "AISessions",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AISessions", targets: ["AISessions"]),
        .library(name: "AISessionsCore", targets: ["AISessionsCore"]),
    ],
    targets: [
        // Pure logic: session sources, tracker engine, routing plans. No AppKit.
        .target(
            name: "AISessionsCore",
            path: "Sources/AISessionsCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // The menu-bar app (AppKit + UserNotifications).
        .executableTarget(
            name: "AISessions",
            dependencies: ["AISessionsCore"],
            path: "Sources/AISessions"
        ),
        .testTarget(
            name: "AISessionsCoreTests",
            dependencies: ["AISessionsCore"],
            path: "Tests/AISessionsCoreTests"
        ),
        // App-layer logic (menu text, notification policy, state files, routing
        // execution) — @testable import of the executable target.
        .testTarget(
            name: "AISessionsAppTests",
            dependencies: ["AISessions", "AISessionsCore"],
            path: "Tests/AISessionsAppTests"
        ),
    ],
    // Swift 5 mode on purpose: UNUserNotificationCenter calls its delegate on a
    // background queue, and Swift 6 mode turns a main-actor delegate into a
    // runtime isolation crash. The code is still written main-actor-correct.
    swiftLanguageModes: [.v5]
)
