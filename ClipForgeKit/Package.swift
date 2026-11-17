// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClipForgeKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ClipForgeKit", targets: ["ClipForgeKit"]),          // Mac app (engine + UI)
        .library(name: "ClipForgeMobile", targets: ["ClipForgeMobile"]),    // iPhone companion
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "1.1.1"),
    ],
    targets: [
        // Themes, shared data types and the companion protocol: macOS + iOS.
        .target(name: "ClipForgeShared", resources: [.copy("Theme/Fonts")]),
        .target(name: "ClipForgeKit", dependencies: ["ClipForgeShared", .product(name: "WhisperKit", package: "WhisperKit")],
                resources: [.process("ProEditor/Styles")]),
        .target(name: "ClipForgeMobile", dependencies: ["ClipForgeShared"]),
        .testTarget(name: "ClipForgeKitTests", dependencies: ["ClipForgeKit", "ClipForgeShared"]),
    ]
)
