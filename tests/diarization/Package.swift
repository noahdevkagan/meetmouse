// swift-tools-version:5.10
import PackageDescription

// Speaker-attribution rig: compiles the app's REAL SpeakerDiarizer.swift
// (via symlink) against the same pinned FluidAudio the app uses, feeds it a
// scripted multi-voice call, and scores the live labels and the whole-call
// final pass against who actually spoke.
let package = Package(
    name: "DiarizationRig",
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
