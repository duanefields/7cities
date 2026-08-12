// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SevenCitiesCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SevenCitiesCore", targets: ["SevenCitiesCore"]),
        // The viewer as a library, so the command below and the Xcode app
        // target share one implementation instead of drifting apart.
        .library(name: "ViewerKit", targets: ["ViewerKit"]),
        .executable(name: "MapViewer", targets: ["MapViewer"]),
        .executable(name: "Extract", targets: ["Extract"]),
    ],
    targets: [
        .target(name: "SevenCitiesCore"),
        .target(name: "ViewerKit", dependencies: ["SevenCitiesCore"]),
        .executableTarget(name: "MapViewer", dependencies: ["SevenCitiesCore", "ViewerKit"]),
        .executableTarget(name: "Extract", dependencies: ["SevenCitiesCore"]),
        .testTarget(
            name: "SevenCitiesCoreTests",
            dependencies: ["SevenCitiesCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
