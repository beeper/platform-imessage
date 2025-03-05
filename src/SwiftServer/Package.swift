// swift-tools-version:5.3

import PackageDescription

let package = Package(
    name: "SwiftServer",
    platforms: [.macOS(.v10_15)],
    products: [
        .library(
            name: "SwiftServer",
            type: .dynamic,
            targets: ["SwiftServer"]
        ),
        // The dynamic target will cause linker errors in Xcode.
        // This target can be selected in Xcode for development.
        .library(
            name: "SwiftServer-Auto",
            targets: ["SwiftServer"]
        ),
    ],
    dependencies: [
        .package(path: "../../node_modules/node-swift"),
        .package(url: "https://github.com/sindresorhus/ExceptionCatcher", from: "2.0.1"),
        .package(url: "https://github.com/beeper/PHTCommon.git", .revision("e45a24a6febb560578581c88b60b048bdb9649ea")),
        .package(url: "https://github.com/TextsHQ/BetterSwiftAX", .branch("main")),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "SwiftServer",
            dependencies: [
                "BetterSwiftAX",
                "ExceptionCatcher",
                "SwiftServerFoundation",
                .product(name: "NodeAPI", package: "node-swift"),
                .product(name: "NodeModuleSupport", package: "node-swift"),
                .product(name: "PHTClient", package: "PHTCommon"),
                "CUnfairLock",
                "EmojiSPI",
            ]
        ),
        .target(name: "EmojiSPI"),
        .testTarget(name: "EmojiSPITests", dependencies: ["EmojiSPI"]),
        .target(
            name: "CUnfairLock",
            dependencies: []
        ),
        .target(
            name: "SwiftServerFoundation",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
            ]
        )
    ]
)
