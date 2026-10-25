// swift-tools-version:5.9
import PackageDescription

// Four logical boundaries only (ADR set in docs/adr/):
//   BSideCore           pure domain: catalog, desired/runtime state, PlaybackPolicy, IPC models
//   BSidePlatform       all macOS-facing code: assets, AVFoundation support, monitors, DesktopHost
//   BSideWallpaperAgent disposable playback process
//   BSideControlApp     long-running menu-bar control process
// Dependency rule: Core <- Platform <- {Agent, ControlApp}. Agent and ControlApp never depend on each other.
//
// BSideTestRunner: in-house deterministic test executable (ADR-009) — the CLT-only toolchain
// on this machine ships neither XCTest nor Swift Testing. Run via scripts/run_tests.sh.
let package = Package(
    name: "BSideMac",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "BSideCore"),
        .target(name: "BSidePlatform", dependencies: ["BSideCore"], resources: [.copy("Resources/performance-manifest.v1.json")]),
        .executableTarget(name: "BSideWallpaperAgent", dependencies: ["BSideCore", "BSidePlatform"]),
        .executableTarget(name: "BSideControlApp", dependencies: ["BSideCore", "BSidePlatform"]),
        .executableTarget(name: "BSideTestRunner", dependencies: ["BSideCore", "BSidePlatform"]),
    ]
)
