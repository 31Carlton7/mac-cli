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
        .target(name: "MailModule", dependencies: ["Core"]),
        .target(name: "MessagesModule", dependencies: ["Core"]),
        .target(name: "NotesModule", dependencies: ["Core"]),
        .target(name: "MusicModule", dependencies: ["Core"]),
        .target(name: "TVModule", dependencies: ["Core"]),
        .target(name: "ShortcutsModule", dependencies: ["Core"]),
        .target(name: "CallModule", dependencies: ["Core"]),
        .target(name: "FinderModule", dependencies: ["Core"]),
        .executableTarget(
            name: "MacCLI",
            dependencies: ["Core", "CalendarModule", "RemindersModule", "ContactsModule", "MailModule", "MessagesModule", "NotesModule", "MusicModule", "TVModule", "ShortcutsModule", "CallModule", "FinderModule"],
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
        .testTarget(name: "MailModuleTests", dependencies: ["MailModule"]),
        .testTarget(name: "MessagesModuleTests", dependencies: ["MessagesModule"]),
        .testTarget(name: "NotesModuleTests", dependencies: ["NotesModule"]),
        .testTarget(name: "MusicModuleTests", dependencies: ["MusicModule"]),
        .testTarget(name: "TVModuleTests", dependencies: ["TVModule"]),
        .testTarget(name: "ShortcutsModuleTests", dependencies: ["ShortcutsModule"]),
        .testTarget(name: "CallModuleTests", dependencies: ["CallModule"]),
        .testTarget(name: "FinderModuleTests", dependencies: ["FinderModule"]),
    ]
)
