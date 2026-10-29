// swift-tools-version: 5.9
import PackageDescription

// SwiftPM layout: sources under Sources/SushiLauncher/ (compiled
// recursively). Build with ./build-app.sh — it runs `swift build -c release`
// and assembles/signs "build/Sushi Launcher.app".
let package = Package(
    name: "SushiLauncher",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "SushiLauncher",
            path: "Sources/SushiLauncher"
        )
    ]
)
