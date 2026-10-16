// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Hoot",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic with no UI: hook payloads, installer merge, usage parsing, mascot pixels.
        .target(name: "HootCore"),
        // The menu-bar app itself.
        .executableTarget(name: "Hoot", dependencies: ["HootCore"]),
        // Renders Hoot to SVG/PNG/iconset. Used by scripts/build-app.sh.
        .executableTarget(name: "hoot-art", dependencies: ["HootCore"]),
        // XCTest is not available without Xcode, so tests run as a plain executable.
        .executableTarget(name: "HootTests", dependencies: ["HootCore"], path: "Tests/HootTests"),
    ]
)
