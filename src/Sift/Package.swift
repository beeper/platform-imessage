// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Sift",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.0.0"),
        .package(url: "https://github.com/slice/Cool", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "Sift",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                .product(name: "Cool", package: "Cool"),
            ]
        ),
    ]
)
