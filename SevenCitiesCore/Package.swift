// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SevenCitiesCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SevenCitiesCore", targets: ["SevenCitiesCore"])
    ],
    targets: [
        .target(name: "SevenCitiesCore"),
        .testTarget(
            name: "SevenCitiesCoreTests",
            dependencies: ["SevenCitiesCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
