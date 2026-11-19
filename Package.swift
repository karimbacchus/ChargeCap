// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ChargeCap",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "ChargeCapCore", targets: ["ChargeCapCore"]),
        .executable(name: "ChargeCap", targets: ["ChargeCap"]),
        .executable(name: "ChargeCapHelper", targets: ["ChargeCapHelper"])
    ],
    targets: [
        .target(
            name: "ChargeCapCore",
            path: "Sources/ChargeCapCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ChargeCap",
            dependencies: ["ChargeCapCore"],
            path: "Sources/ChargeCap",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ChargeCapHelper",
            dependencies: ["ChargeCapCore"],
            path: "Sources/ChargeCapHelper",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ChargeCapCoreTests",
            dependencies: ["ChargeCapCore"],
            path: "Tests/ChargeCapCoreTests"
        )
    ]
)
