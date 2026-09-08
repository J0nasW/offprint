// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Offprint",
    // macOS 26 is required for Vision's RecognizeDocumentsRequest, which supplies
    // the layout/table/list structure the whole pipeline is built on.
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "OffprintCore", targets: ["OffprintCore"]),
        .executable(name: "offprint-harness", targets: ["offprint-harness"]),
    ],
    targets: [
        // No MLX dependency here on purpose: everything in Core builds and tests
        // with plain `swift test`, which does not need the Metal toolchain.
        .target(name: "OffprintCore"),
        .executableTarget(name: "offprint-harness", dependencies: ["OffprintCore"]),
        .testTarget(name: "OffprintCoreTests", dependencies: ["OffprintCore"]),
    ]
)
