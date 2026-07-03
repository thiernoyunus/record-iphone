// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RecordIphone",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "RecordIphone",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
