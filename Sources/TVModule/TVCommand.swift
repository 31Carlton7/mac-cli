import ArgumentParser
import Core
import Foundation

public struct TVCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "tv",
        abstract: "Control TV.app playback and list the video library.",
        subcommands: [Now.self, Pause.self, Resume.self, List.self, Play.self]
    )

    public init() {}

    struct Now: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show what's playing (state, volume, current item).",
            discussion: """
                The track shape is reused from Music.app's player state: the \
                "artist" field carries the episode's show (empty for a movie), \
                "album" is always empty, and "rating" is a placeholder reused \
                from the same 0-100 -> 0-5 star mapping (0 = unrated).
                """
        )

        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let state = try await TVActions(store: AppleScriptTVStore()).now()
                Output.emit(state, json: output.json)
            }
        }
    }

    struct Pause: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Pause playback.")

        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                try await TVActions(store: AppleScriptTVStore()).pause()
                Output.emitConfirmation(key: "paused", value: "playback", human: "paused",
                                        json: output.json, quiet: output.quiet)
            }
        }
    }

    struct Resume: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Resume (or start) playback.")

        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                try await TVActions(store: AppleScriptTVStore()).resume()
                Output.emitConfirmation(key: "playing", value: "playback", human: "resumed",
                                        json: output.json, quiet: output.quiet)
            }
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List items in the video library.")

        @Option(help: "Maximum items (default: 50).") var limit: Int = 50
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let items = try await TVActions(store: AppleScriptTVStore()).list(limit: limit)
                Output.emit(items, json: output.json)
            }
        }
    }

    struct Play: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Play an item by id.",
            discussion: "Example:\n  mac tv play 1234ABCD --json"
        )

        @Argument(help: "Item id (see 'mac tv list').") var id: String
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                try await TVActions(store: AppleScriptTVStore()).play(id: id)
                Output.emitConfirmation(key: "playing", value: id, human: "playing",
                                        json: output.json, quiet: output.quiet)
            }
        }
    }
}
