// swift-tools-version:5.9
import PackageDescription

// Shared code for the Aria iOS/iPadOS app and its widget extension:
// models, the Supabase + OpenRouter clients, the AI tool layer and sync logic.
// Everything here is plain Foundation so it also builds and tests on Linux.
let package = Package(
    name: "AriaKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AriaKit", targets: ["AriaKit"]),
    ],
    targets: [
        .target(name: "AriaKit"),
        .testTarget(name: "AriaKitTests", dependencies: ["AriaKit"]),
    ]
)
