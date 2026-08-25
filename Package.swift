// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "mac-cli",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "mac", targets: ["MacCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")
    ],
    targets: [
        .target(name: "Core", dependencies: [
            .product(name: "ArgumentParser", package: "swift-argument-parser")
        ]),
        .target(name: "CalendarModule", dependencies: ["Core"]),
        .target(name: "RemindersModule", dependencies: ["Core"]),
        .target(name: "ContactsModule", dependencies: ["Core"]),
        .executableTarget(
            name: "MacCLI",
            dependencies: ["Core", "CalendarModule", "RemindersModule", "ContactsModule"],
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/MacCLI/Info.plist",
                ])
            ]
        ),
        .testTarget(name: "CoreTests", dependencies: ["Core"]),
        .testTarget(name: "CalendarModuleTests", dependencies: ["CalendarModule"]),
        .testTarget(name: "RemindersModuleTests", dependencies: ["RemindersModule"]),
        .testTarget(name: "ContactsModuleTests", dependencies: ["ContactsModule"]),
    ]
)
