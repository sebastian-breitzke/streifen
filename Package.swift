// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Streifen",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.5.5"),
        .package(url: "https://github.com/tmandry/AXSwift.git", from: "0.3.2"),
    ],
    targets: [
        .executableTarget(
            name: "Streifen",
            dependencies: [
                "TOMLKit",
                "AXSwift",
            ],
            path: "Sources/Streifen",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("Carbon"),
            ]
        ),
    ]
)
