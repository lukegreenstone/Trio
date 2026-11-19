// swift-tools-version:5.9
import PackageDescription

// Standalone tests for the Rheos learning core.
// The sources are the app's Rheos/Core files via a symlink, so there is one copy.
// This package does not compile the dosing engine, SMB, UAM, or any device driver.
//
//   swift test --package-path RheosPackage

let package = Package(
    name: "RheosCore",
    products: [
        .library(name: "RheosCore", targets: ["RheosCore"])
    ],
    targets: [
        .target(name: "RheosCore", path: "Sources"),
        .testTarget(name: "RheosCoreTests", dependencies: ["RheosCore"], path: "Tests")
    ]
)
