// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SevenCitiesCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SevenCitiesCore", targets: ["SevenCitiesCore"]),
        .executable(name: "MapViewer", targets: ["MapViewer"]),
        .executable(name: "Extract", targets: ["Extract"]),
    ],
    targets: [
        .target(name: "SevenCitiesCore"),
        .executableTarget(name: "MapViewer", dependencies: ["SevenCitiesCore"]),
        .executableTarget(name: "Extract", dependencies: ["SevenCitiesCore"]),
        .testTarget(
            name: "SevenCitiesCoreTests",
            dependencies: ["SevenCitiesCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
