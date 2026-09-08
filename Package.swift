// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NetBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "NetBar", targets: ["NetBar"]),
        .executable(name: "NetBarMiniNetworkGuardian", targets: ["NetBarMiniNetworkGuardian"]),
    ],
    targets: [
        .target(name: "NetworkExecution", path: "Sources/NetworkExecution"),
        .executableTarget(
            name: "NetBar",
            dependencies: ["NetworkExecution"],
            path: "Sources/NetBar",
            resources: [
                .copy("Resources/MiniLinkHelper"),
                .copy("Resources/RouteSafetyHelper")
            ],
            linkerSettings: [
                .unsafeFlags(["-framework", "Cocoa"]),
                .unsafeFlags(["-framework", "SwiftUI"]),
                .unsafeFlags(["-framework", "CoreWLAN"]),
                .unsafeFlags(["-framework", "CoreLocation"]),
            ]
        ),
        .executableTarget(
            name: "NetBarMiniNetworkGuardian",
            dependencies: ["NetBarMiniNetworkGuardianSupport", "NetworkExecution"],
            path: "Sources/NetBarMiniNetworkGuardian",
            linkerSettings: [
                .unsafeFlags(["-framework", "SystemConfiguration"]),
            ]
        ),
        .target(
            name: "NetBarMiniNetworkGuardianSupport",
            path: "Sources/NetBarMiniNetworkGuardianSupport"
        ),
        .testTarget(
            name: "NetBarTests",
            dependencies: ["NetBar", "NetBarMiniNetworkGuardianSupport", "NetworkExecution"],
            path: "Tests/NetBarTests"
        )
    ]
)
