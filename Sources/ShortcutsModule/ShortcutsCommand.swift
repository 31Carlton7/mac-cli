import ArgumentParser
import Core
import Foundation

public struct ShortcutsCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "shortcuts",
        abstract: "List and run Shortcuts.app shortcuts.",
        subcommands: [List.self, Run.self]
    )

    public init() {}

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List shortcuts, sorted by name.")

        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let items = try await ShortcutActions(store: AppleScriptShortcutStore()).list()
                Output.emit(items, json: output.json)
            }
        }
    }

    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run a shortcut by name (or id, with --id) and print its output.",
            discussion: """
                Shortcuts run is the escape hatch for apps mac-cli can't script \
                directly: wrap the task in a Shortcut and run it here. An ambiguous \
                name (two shortcuts sharing it) lists candidates -- resolve with \
                --id and the exact id from 'mac shortcuts list'.

                The output is the shortcut's return value, not a confirmation --
                like any other read in this CLI, it always prints (--quiet has no
                effect on it) and prints nothing when the shortcut returns nothing.

                Examples:
                  mac shortcuts run "Get Weather"
                  mac shortcuts run 1234ABCD-... --id
                  mac shortcuts run "Uppercase" --input "hello" --json
                """
        )

        @Argument(help: "Shortcut name, or id when --id is passed.") var nameOrID: String
        @Option(help: "Text input to pass to the shortcut.") var input: String?
        @Flag(help: "Treat the argument as an exact id instead of a name.") var id = false
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let result = try await ShortcutActions(store: AppleScriptShortcutStore())
                    .run(nameOrID: nameOrID, input: input, isID: id)
                if output.json {
                    // Never string-interpolate user-derived output into JSON -- it may
                    // contain quotes/control characters that would corrupt the envelope.
                    let data = try! JSONSerialization.data(withJSONObject: ["output": result], options: [.sortedKeys])
                    print(String(data: data, encoding: .utf8)!)
                } else if !result.isEmpty {
                    // This is a payload (the shortcut's return value), not a
                    // confirmation echo -- reads in this CLI always print, so
                    // --quiet does not gate it. Empty output prints nothing.
                    print(result)
                }
            }
        }
    }
}
