// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Peerly",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "Peerly",
            targets: ["Peerly"]
        ),
    ],
    targets: [
        .target(
            name: "Peerly"
        ),
    ]
)
