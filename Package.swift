// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Needle",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .executable(name: "Needle", targets: ["Needle"])
    ],
    targets: [
        .target(name: "NeedleCore"),
        .executableTarget(
            name: "Needle",
            dependencies: ["NeedleCore"],
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
                .linkedFramework("WebKit")
            ]
        ),
        .executableTarget(name: "NeedleCheck", dependencies: ["NeedleCore"])
    ]
)
