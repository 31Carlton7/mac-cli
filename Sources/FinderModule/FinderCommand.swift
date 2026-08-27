import ArgumentParser
import Core
import Foundation

public struct FinderCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "finder",
        abstract: "Inspect and act on Finder's selection, files, and disks.",
        discussion: """
            Finder is a GUI-state module — it reflects and drives what's on \
            screen (the current selection, revealing/opening a file, disks). \
            For bulk or scripted file operations, use your shell instead.
            """,
        subcommands: [Selection.self, Reveal.self, Open.self, Trash.self, Disks.self, Eject.self]
    )

    public init() {}

    struct Selection: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the items currently selected in Finder.")

        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let items = try await FinderActions(store: AppleScriptFinderStore()).selection()
                Output.emit(items, json: output.json)
            }
        }
    }

    struct Reveal: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Reveal a file or folder in a Finder window.")

        @Argument(help: "Path to reveal (relative paths and ~ are resolved).") var path: String
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let actions = FinderActions(store: AppleScriptFinderStore())
                let resolved = try actions.resolve(path: path)
                try await actions.reveal(path: path)
                Output.emitConfirmation(key: "revealed", value: resolved, human: "revealed",
                                        json: output.json, quiet: output.quiet)
            }
        }
    }

    struct Open: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Open a file or folder with its default application.")

        @Argument(help: "Path to open (relative paths and ~ are resolved).") var path: String
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let actions = FinderActions(store: AppleScriptFinderStore())
                let resolved = try actions.resolve(path: path)
                try await actions.open(path: path)
                Output.emitConfirmation(key: "opened", value: resolved, human: "opened",
                                        json: output.json, quiet: output.quiet)
            }
        }
    }

    struct Trash: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Move a file or folder to the Trash (recoverable — this is not a permanent delete).",
            discussion: """
                This is the recoverable delete: the item goes to the Trash, \
                same as dragging it there in Finder, and can be restored until \
                the Trash is emptied. Prefer this over 'rm' for user files.
                """
        )

        @Argument(help: "Path to trash (relative paths and ~ are resolved).") var path: String
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let actions = FinderActions(store: AppleScriptFinderStore())
                let resolved = try actions.resolve(path: path)
                try await actions.trash(path: path)
                Output.emitConfirmation(key: "trashed", value: resolved, human: "trashed",
                                        json: output.json, quiet: output.quiet)
            }
        }
    }

    struct Disks: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List mounted disks and volumes.")

        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let disks = try await FinderActions(store: AppleScriptFinderStore()).disks()
                Output.emit(disks, json: output.json)
            }
        }
    }

    struct Eject: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Eject a disk by name (see 'mac finder disks').")

        @Argument(help: "Disk name (matched case-insensitively; see 'mac finder disks').") var name: String
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                try await FinderActions(store: AppleScriptFinderStore()).eject(name: name)
                Output.emitConfirmation(key: "ejected", value: name, human: "ejected",
                                        json: output.json, quiet: output.quiet)
            }
        }
    }
}
