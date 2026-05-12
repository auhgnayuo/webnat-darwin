// swift-tools-version: 5.5
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Webnat",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15)
    ],
    products: [
        .library(
            name: "Webnat",
            targets: ["Webnat"]),
    ],
    targets: [
        .target(
            name: "Webnat",
            dependencies: [],
            resources: [
                .process("PrivacyInfo.xcprivacy")
            ]
        ),
        .testTarget(
            name: "WebnatTests",
            dependencies: ["Webnat"]),
    ]
)
