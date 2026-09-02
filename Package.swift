// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SedentaryDebuff",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "SedentaryDebuff", targets: ["SedentaryDebuff"]),
        .executable(name: "CaretProbe", targets: ["CaretProbe"]),
        .executable(name: "VoiceIME", targets: ["VoiceIME"]),
    ],
    targets: [
        .executableTarget(
            name: "SedentaryDebuff",
            path: "Sources/SedentaryDebuff",
            resources: [
                .process("Resources"),
                .copy("../../App/appicon.png"),
            ]
        ),
        .executableTarget(
            name: "CaretProbe",
            path: "Sources/CaretProbe"
        ),
        .executableTarget(
            name: "VoiceIME",
            path: "Sources/VoiceIME"
        ),
    ]
)
