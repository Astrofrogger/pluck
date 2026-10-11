// swift-tools-version:6.2
import Foundation
import PackageDescription

/// Frameworks newer than Pluck's minimum macOS (local AI features). Weak-linked, so Pluck still
/// launches on older systems and simply hides what they can't run.
let weakFrameworks = ["FoundationModels", "Translation", "CoreAI"]

/// Which Pluck to build: Pluck Studio (everything, the default) or basic Pluck (downloads, the
/// Library, sharing and converting; set PLUCK_EDITION=basic). Basic leaves out the AI, editing
/// and Edit Anywhere code entirely, and with it the speaker-label package.
let studio = ProcessInfo.processInfo.environment["PLUCK_EDITION"] != "basic"

let package = Package(
    name: "Pluck",
    platforms: [.macOS(.v14)],
    dependencies: studio ? [
        // Speaker labels (who said what) with an on-device model. Its optional prebuilt text
        // normalizer is left out: Pluck only uses the diarizer.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: []),
    ] : [],
    targets: [
        .executableTarget(
            name: "Pluck",
            dependencies: studio ? [.product(name: "FluidAudio", package: "FluidAudio")] : [],
            path: "Sources/Pluck",
            exclude: studio ? [] : ["AI", "Edit", "Remote", "Studio"],
            swiftSettings: [.swiftLanguageMode(.v5)] + (studio ? [.define("STUDIO")] : []),
            linkerSettings: [.unsafeFlags(weakFrameworks.flatMap { ["-Xlinker", "-weak_framework", "-Xlinker", $0] })]
        )
    ]
)
