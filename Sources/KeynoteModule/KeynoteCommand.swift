import ArgumentParser
import Core
import Foundation

public struct KeynoteCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "keynote",
        abstract: "Create, edit, and export Keynote presentations.",
        discussion: """
            Keynote scripting operates on OPEN documents: 'docs' lists them, \
            'new' creates (and opens) one, and the other verbs address open \
            documents by NAME as shown in 'mac keynote docs'.
            """,
        subcommands: [Docs.self, New.self, AddSlide.self, Slides.self, Export.self]
    )

    public init() {}

    struct Docs: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List open Keynote documents.")

        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let docs = try await KeynoteActions(store: AppleScriptKeynoteStore()).docs()
                Output.emit(docs, json: output.json)
            }
        }
    }

    struct New: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create a new presentation, optionally themed and saved to a path.",
            discussion: """
                Without --out the document stays open and unsaved ("Untitled"); \
                with --out it is saved there immediately.

                Examples:
                  mac keynote new
                  mac keynote new --theme White --out ~/Desktop/pitch.key
                """
        )

        @Option(help: "Theme name (matched case-insensitively, e.g. \"White\").") var theme: String?
        @Option(help: "Save the new document at this path (parent directory must exist).") var out: String?
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let info = try await KeynoteActions(store: AppleScriptKeynoteStore()).newDoc(theme: theme, out: out)
                if output.json || !output.quiet { Output.emit(info, json: output.json) }
            }
        }
    }

    struct AddSlide: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add-slide",
            abstract: "Append a slide to an open presentation.",
            discussion: "Example:\n  mac keynote add-slide pitch.key --title \"Roadmap\" --body \"Q3 milestones\""
        )

        @Argument(help: "Document name (see 'mac keynote docs').") var doc: String
        @Option(help: "Slide title.") var title: String
        @Option(help: "Slide body text (optional).") var body: String?
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                try await KeynoteActions(store: AppleScriptKeynoteStore()).addSlide(doc: doc, title: title, body: body)
                Output.emitConfirmation(key: "added", value: title, human: "added",
                                        json: output.json, quiet: output.quiet)
            }
        }
    }

    struct Slides: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List an open presentation's slides (number and title).")

        @Argument(help: "Document name (see 'mac keynote docs').") var doc: String
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let slides = try await KeynoteActions(store: AppleScriptKeynoteStore()).slides(doc: doc)
                Output.emit(slides, json: output.json)
            }
        }
    }

    struct Export: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Export an open presentation to PDF or PowerPoint.",
            discussion: """
                Exports never overwrite an existing file unless --force is \
                given. The output path's parent directory must exist.

                Example:
                  mac keynote export pitch.key --format pdf --out ~/Desktop/pitch.pdf
                """
        )

        @Argument(help: "Document name (see 'mac keynote docs').") var doc: String
        @Option(help: "Export format: pdf or pptx.") var format: String
        @Option(help: "Output file path.") var out: String
        @Flag(help: "Overwrite the output file if it already exists.") var force = false
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let path = try await KeynoteActions(store: AppleScriptKeynoteStore())
                    .export(doc: doc, format: format, out: out, force: force)
                Output.emitConfirmation(key: "exported", value: path, human: "exported",
                                        json: output.json, quiet: output.quiet)
            }
        }
    }
}
