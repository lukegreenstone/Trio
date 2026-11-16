// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "HandyFreiDrivers",
    platforms: [
        .iOS(.v17),
        .watchOS(.v10)
    ],
    products: [
        .library(name: "HandyFreiDrivers", targets: ["HandyFreiDrivers"])
    ],
    targets: [
        .target(
            name: "RoundWhiteDiscWatch",
            path: "Sources/RoundWhiteDiscWatch",
            resources: [
                .process("Resources/Localizations")
            ]
        ),
        .target(
            name: "HandyFreiDrivers",
            dependencies: ["RoundWhiteDiscWatch"],
            path: "Sources/HandyFreiDrivers"
        )
    ]
)
