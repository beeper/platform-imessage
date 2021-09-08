// swift-tools-version:5.3

import PackageDescription

let package = Package(
    name: "SwiftServer",
    products: [
        .library(
            name: "SwiftServer",
            targets: ["SwiftServer"]
        ),
    ],
    dependencies: [
        .package(path: "../../node_modules/node-swift")
    ],
    targets: [
        .target(
            name: "SwiftServer",
            dependencies: [
                .product(name: "NodeAPI", package: "node-swift")
            ]
        ),
    ]
)
