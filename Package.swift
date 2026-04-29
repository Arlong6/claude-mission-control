// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MissionControl",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "MissionControl",
            path: "Sources/MissionControl",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
    ]
)
