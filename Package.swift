// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "UsageTouchBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "usage-touchbar", targets: ["UsageTouchBar"])
    ],
    targets: [
        .executableTarget(
            name: "UsageTouchBar",
            path: "Sources/UsageTouchBar"
        )
    ]
)
