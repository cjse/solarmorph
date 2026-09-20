// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "morph",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "MorphCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "morph",
            dependencies: ["MorphCore"],
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                // CoreBluetooth needs NSBluetoothAlwaysUsageDescription. A bare
                // executable has no bundle, so the Info.plist goes into the binary.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/morph/Info.plist",
                ]),
            ]
        ),
        .testTarget(
            name: "MorphCoreTests",
            dependencies: ["MorphCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
