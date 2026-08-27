import ArgumentParser
import Core
import Foundation

public struct NotesCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "notes",
        abstract: "Read and write Apple Notes.",
        subcommands: [List.self, Search.self, Read.self, Add.self, Append.self,
                      Edit.self, Delete.self, Folders.self]
    )

    public init() {}

    struct ScopeOptions: ParsableArguments {
        @Option(help: "Only this folder (by name; add --account if the name exists in several accounts).")
        var folder: String?
        @Option(help: "Only this account (e.g. iCloud).")
        var account: String?
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List notes, newest first. Recently Deleted is excluded unless named explicitly.",
            discussion: "Examples:\n  mac notes list --limit 10\n  mac notes list --folder Ideas --json\n  mac notes list --folder Notes --account Work"
        )

        @OptionGroup var scope: ScopeOptions
        @Option(help: "Maximum notes (default: 20).") var limit: Int = 20
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let items = try await NoteActions(store: AppleScriptNoteStore())
                    .list(folder: scope.folder, account: scope.account, limit: limit)
                Output.emit(items, json: output.json)
            }
        }
    }

    struct Search: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Search note titles and body text.",
            discussion: "Example:\n  mac notes search \"brunch\" --limit 10 --json"
        )

        @Argument(help: "Text to match in titles and bodies (case-insensitive).") var query: String
        @OptionGroup var scope: ScopeOptions
        @Option(help: "Maximum notes (default: 20).") var limit: Int = 20
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let items = try await NoteActions(store: AppleScriptNoteStore())
                    .search(query: query, folder: scope.folder, account: scope.account, limit: limit)
                Output.emit(items, json: output.json)
            }
        }
    }

    struct Read: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show a note including its body, by exact id.",
            discussion: "Body is plain text by default; --html returns Notes' raw HTML."
        )

        @Argument(help: "Note id from 'mac notes list'.") var id: String
        @Flag(help: "Return the raw HTML body instead of plain text.") var html = false
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let item = try await NoteActions(store: AppleScriptNoteStore()).read(id: id, html: html)
                Output.emit(item, json: output.json)
            }
        }
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create a note.",
            discussion: "Example:\n  mac notes add \"Meeting notes\" --body \"Attendees: ...\" --folder Work"
        )

        @Argument(help: "Note title (becomes the first line).") var title: String
        @Option(help: "Note body text.") var body: String = ""
        @OptionGroup var scope: ScopeOptions
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let item = try await NoteActions(store: AppleScriptNoteStore())
                    .add(title: title, body: body, folder: scope.folder, account: scope.account)
                if output.json || !output.quiet { Output.emit(item, json: output.json) }
            }
        }
    }

    struct Append: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Append a paragraph to a note, by exact id."
        )

        @Argument(help: "Note id from 'mac notes list'.") var id: String
        @Argument(help: "Text to append.") var text: String
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                try await NoteActions(store: AppleScriptNoteStore()).append(id: id, text: text)
                Output.emitConfirmation(key: "appended", value: id, human: "appended to",
                                        json: output.json, quiet: output.quiet)
            }
        }
    }

    struct Edit: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Edit a note by exact id.",
            discussion: "--body replaces the note's content (the title line is preserved); --title renames."
        )

        @Argument(help: "Note id from 'mac notes list'.") var id: String
        @Option(help: "New title.") var title: String?
        @Option(help: "New body text (replaces existing content).") var body: String?
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                try await NoteActions(store: AppleScriptNoteStore()).edit(id: id, title: title, body: body)
                Output.emitConfirmation(key: "edited", value: id, human: "edited",
                                        json: output.json, quiet: output.quiet)
            }
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Move a note to Recently Deleted, by exact id (recoverable in Notes.app)."
        )

        @Argument(help: "Note id from 'mac notes list'.") var id: String
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                try await NoteActions(store: AppleScriptNoteStore()).delete(id: id)
                Output.emitConfirmation(key: "deleted", value: id, human: "deleted",
                                        json: output.json, quiet: output.quiet)
            }
        }
    }

    struct Folders: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List Notes folders across accounts (Recently Deleted excluded)."
        )

        @Option(help: "Only this account.") var account: String?
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let folders = try await NoteActions(store: AppleScriptNoteStore()).folders(account: account)
                Output.emit(folders, json: output.json)
            }
        }
    }
}
