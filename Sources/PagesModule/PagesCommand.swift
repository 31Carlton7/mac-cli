import ArgumentParser
import Core
import Foundation

public struct PagesCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "pages",
        abstract: "Create, edit, and export Pages documents.",
        discussion: """
            Pages scripting operates on OPEN documents: 'docs' lists them, \
            'new' creates (and opens) one, and the other verbs address open \
            documents by NAME as shown in 'mac pages docs'.
            """,
        subcommands: [Docs.self, New.self, GetBody.self, SetBody.self, Append.self, Export.self]
    )

    public init() {}

    struct Docs: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List open Pages documents.")

        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let docs = try await PagesActions(store: AppleScriptPagesStore()).docs()
                Output.emit(docs, json: output.json)
            }
        }
    }

    struct New: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create a new document, optionally saved to a path.",
            discussion: """
                Without --out the document stays open and unsaved ("Untitled"); \
                with --out it is saved there immediately.

                Examples:
                  mac pages new
                  mac pages new --out ~/Desktop/letter.pages
                """
        )

        @Option(help: "Save the new document at this path (parent directory must exist).") var out: String?
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let info = try await PagesActions(store: AppleScriptPagesStore()).newDoc(out: out)
                if output.json || !output.quiet { Output.emit(info, json: output.json) }
            }
        }
    }

    struct GetBody: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "get-body",
            abstract: "Print an open document's body text.",
            discussion: """
                The output is the document's body text, not a confirmation -- \
                like any other read in this CLI, it always prints (--quiet has \
                no effect on it) and prints nothing when the body is empty.

                Example:
                  mac pages get-body letter.pages
                """
        )

        @Argument(help: "Document name (see 'mac pages docs').") var doc: String
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let body = try await PagesActions(store: AppleScriptPagesStore()).getBody(doc: doc)
                if output.json {
                    // Never string-interpolate user-derived output into JSON -- it may
                    // contain quotes/control characters that would corrupt the envelope.
                    let data = try! JSONSerialization.data(withJSONObject: ["body": body], options: [.sortedKeys])
                    print(String(data: data, encoding: .utf8)!)
                } else if !body.isEmpty {
                    // This is a payload (the document's body text), not a
                    // confirmation echo -- reads in this CLI always print, so
                    // --quiet does not gate it. An empty body prints nothing.
                    print(body)
                }
            }
        }
    }

    struct SetBody: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set-body",
            abstract: "Replace an open document's body text.",
            discussion: "Example:\n  mac pages set-body letter.pages --text \"Dear Sam,\""
        )

        @Argument(help: "Document name (see 'mac pages docs').") var doc: String
        @Option(help: "Replacement body text.") var text: String
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                try await PagesActions(store: AppleScriptPagesStore()).setBody(doc: doc, text: text)
                Output.emitConfirmation(key: "set", value: doc, human: "set body of",
                                        json: output.json, quiet: output.quiet)
            }
        }
    }

    struct Append: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Append a paragraph to an open document's body text.",
            discussion: "Example:\n  mac pages append letter.pages --text \"PS: see you soon.\""
        )

        @Argument(help: "Document name (see 'mac pages docs').") var doc: String
        @Option(help: "Paragraph to append.") var text: String
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                try await PagesActions(store: AppleScriptPagesStore()).appendBody(doc: doc, text: text)
                Output.emitConfirmation(key: "appended", value: doc, human: "appended to",
                                        json: output.json, quiet: output.quiet)
            }
        }
    }

    struct Export: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Export an open document to PDF or Word.",
            discussion: """
                Exports never overwrite an existing file unless --force is \
                given. The output path's parent directory must exist.

                Example:
                  mac pages export letter.pages --format pdf --out ~/Desktop/letter.pdf
                """
        )

        @Argument(help: "Document name (see 'mac pages docs').") var doc: String
        @Option(help: "Export format: pdf or docx.") var format: String
        @Option(help: "Output file path.") var out: String
        @Flag(help: "Overwrite the output file if it already exists.") var force = false
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let path = try await PagesActions(store: AppleScriptPagesStore())
                    .export(doc: doc, format: format, out: out, force: force)
                Output.emitConfirmation(key: "exported", value: path, human: "exported",
                                        json: output.json, quiet: output.quiet)
            }
        }
    }
}
