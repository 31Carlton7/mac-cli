import ArgumentParser
import Core
import Foundation

public struct MusicCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "music",
        abstract: "Control Music.app playback and manage playlists.",
        subcommands: [Now.self, Play.self, Pause.self, Next.self, Prev.self, Volume.self,
                      Search.self, Playlists.self, PlaylistCreate.self, PlaylistAdd.self,
                      PlaylistRemove.self, PlaylistDelete.self, Rate.self]
    )

    public init() {}

    struct Now: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show what's playing (state, volume, current track)."
        )

        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let state = try await MusicActions(store: AppleScriptMusicStore()).now()
                Output.emit(state, json: output.json)
            }
        }
    }

    struct Play: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Play a playlist or track, or resume playback.",
            discussion: """
                Without --playlist or --track-id, resumes whatever Music.app had \
                paused (equivalent to pressing play).

                Examples:
                  mac music play
                  mac music play --playlist Workout
                  mac music play --track-id 1234ABCD --json
                """
        )

        @Option(help: "Playlist name or id (see 'mac music playlists'). Ambiguous names list candidates.") var playlist: String?
        @Option(name: .customLong("track-id"), help: "Track id (see 'mac music search').") var trackID: String?
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                try await MusicActions(store: AppleScriptMusicStore()).play(playlist: playlist, trackID: trackID)
                let resuming = playlist == nil && trackID == nil
                let value = trackID ?? playlist ?? "playback"
                Output.emitConfirmation(key: "playing", value: value, human: resuming ? "resumed" : "playing",
                                        json: output.json, quiet: output.quiet)
            }
        }
    }

    struct Pause: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Pause playback.")

        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                try await MusicActions(store: AppleScriptMusicStore()).pause()
                Output.emitConfirmation(key: "paused", value: "playback", human: "paused",
                                        json: output.json, quiet: output.quiet)
            }
        }
    }

    struct Next: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Skip to the next track.")

        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                try await MusicActions(store: AppleScriptMusicStore()).next()
                Output.emitConfirmation(key: "skipped", value: "forward", human: "skipped",
                                        json: output.json, quiet: output.quiet)
            }
        }
    }

    struct Prev: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Return to the previous track.")

        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                try await MusicActions(store: AppleScriptMusicStore()).previous()
                Output.emitConfirmation(key: "skipped", value: "back", human: "skipped",
                                        json: output.json, quiet: output.quiet)
            }
        }
    }

    struct Volume: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show or set the sound volume (0-100).",
            discussion: "Example:\n  mac music volume\n  mac music volume 75"
        )

        @Argument(help: "New volume, 0-100. Omit to show the current volume.") var level: Int?
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let result = try await MusicActions(store: AppleScriptMusicStore()).volume(level)
                Output.emitConfirmation(key: "volume", value: String(result), human: "volume",
                                        json: output.json, quiet: output.quiet)
            }
        }
    }

    struct Search: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Search the library for tracks.",
            discussion: "Example:\n  mac music search \"here comes the sun\" --limit 5 --json"
        )

        @Argument(help: "Text to match (title, artist, album, composer).") var query: String
        @Option(help: "Maximum tracks (default: 20).") var limit: Int = 20
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let items = try await MusicActions(store: AppleScriptMusicStore()).search(query: query, limit: limit)
                Output.emit(items, json: output.json)
            }
        }
    }

    struct Playlists: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List playlists (user and system).")

        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let items = try await MusicActions(store: AppleScriptMusicStore()).playlists()
                Output.emit(items, json: output.json)
            }
        }
    }

    struct PlaylistCreate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "playlist-create",
            abstract: "Create a new user playlist."
        )

        @Argument(help: "Playlist name.") var name: String
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let info = try await MusicActions(store: AppleScriptMusicStore()).playlistCreate(name: name)
                if output.json || !output.quiet { Output.emit(info, json: output.json) }
            }
        }
    }

    struct PlaylistAdd: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "playlist-add",
            abstract: "Add a track to a user playlist, by playlist name/id and track id."
        )

        @Argument(help: "Playlist name or id.") var playlist: String
        @Argument(help: "Track id (see 'mac music search').") var trackID: String
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                try await MusicActions(store: AppleScriptMusicStore()).playlistAdd(playlist: playlist, trackID: trackID)
                Output.emitConfirmation(key: "added", value: trackID, human: "added",
                                        json: output.json, quiet: output.quiet)
            }
        }
    }

    struct PlaylistRemove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "playlist-remove",
            abstract: "Remove a track from a user playlist, by playlist name/id and track id."
        )

        @Argument(help: "Playlist name or id.") var playlist: String
        @Argument(help: "Track id (see 'mac music search').") var trackID: String
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                try await MusicActions(store: AppleScriptMusicStore()).playlistRemove(playlist: playlist, trackID: trackID)
                Output.emitConfirmation(key: "removed", value: trackID, human: "removed",
                                        json: output.json, quiet: output.quiet)
            }
        }
    }

    struct PlaylistDelete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "playlist-delete",
            abstract: "Delete a user playlist, by exact name."
        )

        @Argument(help: "Playlist name.") var name: String
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                try await MusicActions(store: AppleScriptMusicStore()).playlistDelete(name: name)
                Output.emitConfirmation(key: "deleted", value: name, human: "deleted",
                                        json: output.json, quiet: output.quiet)
            }
        }
    }

    struct Rate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Rate a track, 0-5 stars.",
            discussion: "0 clears the rating (unrated) rather than setting a 0-star rating.\nExample:\n  mac music rate 1234ABCD 4"
        )

        @Argument(help: "Track id (see 'mac music search').") var trackID: String
        @Argument(help: "Stars, 0-5 (0 = unrated).") var stars: Int
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                try await MusicActions(store: AppleScriptMusicStore()).rate(trackID: trackID, stars: stars)
                Output.emitConfirmation(key: "rated", value: trackID, human: "rated",
                                        json: output.json, quiet: output.quiet)
            }
        }
    }
}
