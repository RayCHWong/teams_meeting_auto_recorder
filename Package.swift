// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TeamsMeetingAutoRecorder",
    platforms: [.macOS("26.0")],   // matches LSMinimumSystemVersion; the Speech and tap APIs are macOS 26
    products: [
        .library(name: "RecorderKit", targets: ["RecorderKit"]),
        .executable(name: "TapSpike", targets: ["TapSpike"]),
        .executable(name: "MeetingRecorder", targets: ["MeetingRecorder"]),
    ],
    targets: [
        .target(
            name: "RecorderKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Phase 1 diagnostic harness. Same capture path as the app, no UI in the way.
        .executableTarget(
            name: "TapSpike",
            dependencies: ["RecorderKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "MeetingRecorder",
            dependencies: ["RecorderKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
