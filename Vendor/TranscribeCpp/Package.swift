// swift-tools-version: 5.9
import PackageDescription

// Vendored copy of the official transcribe.cpp Swift bindings (v0.4.2), so the
// app runs Handy's engine and GGUF models natively. The wrapper sources are
// unmodified upstream files; only this manifest differs: upstream resolves the
// xcframework from its own build directory, while this package pins the
// published v0.4.2 release artifact.
let package = Package(
    name: "TranscribeCpp",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "TranscribeCpp", targets: ["TranscribeCpp"]),
    ],
    targets: [
        .binaryTarget(
            name: "CTranscribe",
            url: "https://github.com/handy-computer/transcribe.cpp/releases/download/v0.4.2/TranscribeCpp.xcframework.zip",
            checksum: "650a42ee7836558d3047f328078be2b8a8d4c6e9f6a0a3f4ea145481ad1c1a86"
        ),
        .target(
            name: "TranscribeCpp",
            dependencies: ["CTranscribe"],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedLibrary("z"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
            ]
        ),
    ]
)
