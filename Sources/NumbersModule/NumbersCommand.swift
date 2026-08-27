import ArgumentParser
import Core
import Foundation

public struct NumbersCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "numbers",
        abstract: "Create, edit, and export Numbers spreadsheets.",
        discussion: """
            Numbers scripting operates on OPEN documents: 'docs' lists them, \
            'new' creates (and opens) one, and the other verbs address open \
            documents by NAME as shown in 'mac numbers docs'. Cells use A1 \
            notation inside 1-based --sheet/--table indexes.
            """,
        subcommands: [Docs.self, New.self, GetCell.self, SetCell.self, Export.self]
    )

    public init() {}

    struct Docs: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List open Numbers documents.")

        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let docs = try await NumbersActions(store: AppleScriptNumbersStore()).docs()
                Output.emit(docs, json: output.json)
            }
        }
    }

    struct New: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create a new spreadsheet, optionally saved to a path.",
            discussion: """
                Without --out the document stays open and unsaved ("Untitled"); \
                with --out it is saved there immediately.

                Examples:
                  mac numbers new
                  mac numbers new --out ~/Desktop/budget.numbers
                """
        )

        @Option(help: "Save the new document at this path (parent directory must exist).") var out: String?
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let info = try await NumbersActions(store: AppleScriptNumbersStore()).newDoc(out: out)
                if output.json || !output.quiet { Output.emit(info, json: output.json) }
            }
        }
    }

    struct GetCell: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "get-cell",
            abstract: "Print a cell's value from an open spreadsheet.",
            discussion: """
                The output is the cell's value, not a confirmation -- like any \
                other read in this CLI, it always prints (--quiet has no effect \
                on it) and prints nothing when the cell is empty.

                Example:
                  mac numbers get-cell budget.numbers --cell B2
                """
        )

        @Argument(help: "Document name (see 'mac numbers docs').") var doc: String
        @Option(help: "Cell reference in A1 notation (e.g. B2).") var cell: String
        @Option(help: "Sheet index, 1-based.") var sheet: Int = 1
        @Option(help: "Table index within the sheet, 1-based.") var table: Int = 1
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let value = try await NumbersActions(store: AppleScriptNumbersStore())
                    .getCell(doc: doc, sheet: sheet, table: table, cell: cell)
                if output.json {
                    // Never string-interpolate user-derived output into JSON -- it may
                    // contain quotes/control characters that would corrupt the envelope.
                    let data = try! JSONSerialization.data(withJSONObject: ["value": value], options: [.sortedKeys])
                    print(String(data: data, encoding: .utf8)!)
                } else if !value.isEmpty {
                    // This is a payload (the cell's value), not a confirmation
                    // echo -- reads in this CLI always print, so --quiet does
                    // not gate it. An empty cell prints nothing.
                    print(value)
                }
            }
        }
    }

    struct SetCell: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set-cell",
            abstract: "Set a cell's value in an open spreadsheet.",
            discussion: """
                The value is written as text; Numbers coerces numerics itself.

                Example:
                  mac numbers set-cell budget.numbers --cell B2 --value 42
                """
        )

        @Argument(help: "Document name (see 'mac numbers docs').") var doc: String
        @Option(help: "Cell reference in A1 notation (e.g. B2).") var cell: String
        @Option(help: "Value to write (text; Numbers coerces numerics).") var value: String
        @Option(help: "Sheet index, 1-based.") var sheet: Int = 1
        @Option(help: "Table index within the sheet, 1-based.") var table: Int = 1
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                try await NumbersActions(store: AppleScriptNumbersStore())
                    .setCell(doc: doc, sheet: sheet, table: table, cell: cell, value: value)
                Output.emitConfirmation(key: "set", value: cell.uppercased(), human: "set",
                                        json: output.json, quiet: output.quiet)
            }
        }
    }

    struct Export: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Export an open spreadsheet to PDF, Excel, or CSV.",
            discussion: """
                Exports never overwrite an existing file unless --force is \
                given. The output path's parent directory must exist.

                Example:
                  mac numbers export budget.numbers --format csv --out ~/Desktop/budget.csv
                """
        )

        @Argument(help: "Document name (see 'mac numbers docs').") var doc: String
        @Option(help: "Export format: pdf, xlsx, or csv.") var format: String
        @Option(help: "Output file path.") var out: String
        @Flag(help: "Overwrite the output file if it already exists.") var force = false
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let path = try await NumbersActions(store: AppleScriptNumbersStore())
                    .export(doc: doc, format: format, out: out, force: force)
                Output.emitConfirmation(key: "exported", value: path, human: "exported",
                                        json: output.json, quiet: output.quiet)
            }
        }
    }
}
