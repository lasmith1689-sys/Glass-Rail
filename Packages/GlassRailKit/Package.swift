// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "GlassRailKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "GlassRailKit", targets: ["GlassRailKit"]),
    ],
    targets: [
        .target(
            name: "GlassRailKit",
            path: "Sources/GlassRailKit"
        ),
        // CI-only live check of NJ Transit's feed (see .github/workflows/ci.yml).
        .executableTarget(
            name: "njt-probe",
            dependencies: ["GlassRailKit"],
            path: "Sources/njt-probe"
        ),
        .testTarget(
            name: "GlassRailKitTests",
            dependencies: ["GlassRailKit"],
            path: "Tests/GlassRailKitTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
