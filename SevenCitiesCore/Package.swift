// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SevenCitiesCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SevenCitiesCore", targets: ["SevenCitiesCore"]),
        .executable(name: "MapViewer", targets: ["MapViewer"]),
    ],
    targets: [
        .target(name: "SevenCitiesCore"),
        .executableTarget(name: "MapViewer", dependencies: ["SevenCitiesCore"]),
        .testTarget(
            name: "SevenCitiesCoreTests",
            dependencies: ["SevenCitiesCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
