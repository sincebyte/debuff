// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SedentaryDebuff",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "SedentaryDebuff", targets: ["SedentaryDebuff"]),
    ],
    targets: [
        .executableTarget(
            name: "SedentaryDebuff",
            path: "Sources/SedentaryDebuff",
            resources: [
                .process("Resources"),
            ]
        ),
    ]
)
