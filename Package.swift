// swift-tools-version:6.2
import PackageDescription

/// Frameworks newer than Pluck's minimum macOS (local AI features). Weak-linked, so Pluck still
/// launches on older systems and simply hides what they can't run.
let weakFrameworks = ["FoundationModels", "Translation", "CoreAI"]

let package = Package(
    name: "Pluck",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Pluck",
            path: "Sources/Pluck",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.unsafeFlags(weakFrameworks.flatMap { ["-Xlinker", "-weak_framework", "-Xlinker", $0] })]
        )
    ]
)
