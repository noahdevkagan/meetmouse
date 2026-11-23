// swift-tools-version:5.10
import PackageDescription

// End-to-end download rig: compiles the app's REAL ParakeetDownloadState.swift
// and ParakeetDownloadRetry.swift (via symlinks) against the pinned FluidAudio,
// and downloads Parakeet v3 from Hugging Face through a proxy that cuts the
// connection mid-transfer. Needs the network; run by
// .github/workflows/download-e2e.yml, not the push gate.
let package = Package(
    name: "DownloadRig",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.15.5")
    ],
    targets: [
        .executableTarget(
            name: "rig",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/rig"
        )
    ]
)
