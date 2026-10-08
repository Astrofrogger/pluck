// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Pluck",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Pluck",
            path: "Sources/Pluck",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
