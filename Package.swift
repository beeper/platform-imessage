// swift-tools-version:5.8

import PackageDescription

let includeNodeBridge = Context.environment["IMESSAGE_INCLUDE_NODE_BRIDGE"] == "1"

var products: [Product] = [
    .library(
        name: "IMessage",
        targets: ["IMessage"]
    ),
    .executable(name: "imessage", targets: ["IMessageCLI"]),
]

var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/sindresorhus/ExceptionCatcher", from: "2.0.1"),
    .package(url: "https://github.com/beeper/PHTCommon.git", from: "0.1.0"),
    .package(url: "https://github.com/beeper/BetterSwiftAX.git", from: "0.1.0"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
    .package(url: "https://github.com/apple/swift-collections.git", from: "1.2.0"),
    .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.0.0"),
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.6.1"),
]

var targets: [Target] = [
    .target(
        name: "IMessage",
        dependencies: [
            "BetterSwiftAX",
            "ExceptionCatcher",
            "IMessageCore",
            .product(name: "PHTClient", package: "PHTCommon"),
            "EmojiSPI",
            "IMDatabase",
            .product(name: "Collections", package: "swift-collections"),
        ],
        path: "src/IMessage/Sources/IMessage"
    ),
    .target(
        name: "EmojiSPI",
        dependencies: ["IMessageCore"],
        path: "src/IMessage/Sources/EmojiSPI"
    ),
    .target(
        name: "SQLite",
        dependencies: [
            .product(name: "Logging", package: "swift-log"),
        ],
        path: "src/IMessage/Sources/SQLite"
    ),
    .testTarget(
        name: "SQLiteTests",
        dependencies: ["SQLite"],
        path: "src/IMessage/Sources/SQLiteTests"
    ),
    .target(
        name: "IMDatabase",
        dependencies: [
            .product(name: "Logging", package: "swift-log"),
            .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
            .product(name: "Collections", package: "swift-collections"),
            "SQLite",
            "ExceptionCatcher",
            "IMessageCore",
        ],
        path: "src/IMessage/Sources/IMDatabase"
    ),
    .executableTarget(
        name: "IMessageCLI",
        dependencies: [
            "IMessage",
            "IMessageCore",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ],
        path: "src/IMessage/Sources/IMessageCLI"
    ),
    .testTarget(
        name: "EmojiSPITests",
        dependencies: ["EmojiSPI"],
        path: "src/IMessage/Sources/EmojiSPITests"
    ),
    .testTarget(
        name: "IMessageTests",
        dependencies: ["IMessage"],
        path: "src/IMessage/Sources/IMessageTests",
        resources: [.process("Fixtures")]
    ),
    .target(
        name: "CUnfairLock",
        dependencies: [],
        path: "src/IMessage/Sources/CUnfairLock"
    ),
    .target(
        name: "IMessageCore",
        dependencies: [
            .product(name: "Logging", package: "swift-log"),
            "ExceptionCatcher",
            "CUnfairLock",
        ],
        path: "src/IMessage/Sources/IMessageCore"
    ),
]

if includeNodeBridge {
    products.append(
        .library(
            name: "IMessageNode",
            type: .dynamic,
            targets: ["IMessageNode"]
        )
    )
    dependencies.append(.package(path: "node_modules/node-swift"))
    targets.append(
        .target(
            name: "IMessageNode",
            dependencies: [
                "IMessage",
                "IMessageCore",
                .product(name: "NodeAPI", package: "node-swift"),
                .product(name: "NodeModuleSupport", package: "node-swift"),
            ],
            path: "src/IMessage/Sources/IMessageNode",
            // `node-swift`'s build scripts pass some flags that enable dynamic
            // symbol resolution, which avoids N-API linkage errors at static
            // linking time. Replicate those here for SPM-backed debug builds.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup"])]
        )
    )
}

let package = Package(
    name: "IMessage",
    platforms: [.macOS(.v11)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
