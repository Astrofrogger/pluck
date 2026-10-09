// swift-tools-version:6.2
import PackageDescription

/// Frameworks newer than Pluck's minimum macOS (local AI features). Weak-linked, so Pluck still
/// launches on older systems and simply hides what they can't run.
let weakFrameworks = ["FoundationModels", "Translation", "CoreAI"]

let package = Package(
    name: "Pluck",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Speaker labels (who said what) with an on-device model. Its optional prebuilt text
        // normalizer is left out: Pluck only uses the diarizer.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: []),
    ],
    targets: [
        .executableTarget(
            name: "Pluck",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/Pluck",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.unsafeFlags(weakFrameworks.flatMap { ["-Xlinker", "-weak_framework", "-Xlinker", $0] })]
        )
    ]
)
