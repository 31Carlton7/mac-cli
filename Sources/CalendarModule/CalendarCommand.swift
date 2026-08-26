import ArgumentParser
import Core
import Foundation

public struct CalendarCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "calendar",
        abstract: "Read and write Calendar events.",
        subcommands: [List.self, Add.self, Edit.self, Delete.self, Calendars.self]
    )

    public init() {}

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List events in a date window.",
            discussion: "Examples:\n  mac calendar list\n  mac calendar list --from today --to +7d --calendar Work --json"
        )

        @Option(help: "Window start (default: today).") var from: String?
        @Option(help: "Window end (default: +7d).") var to: String?
        @Option(help: "Only events from this calendar.") var calendar: String?
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let items = try await CalendarActions(store: EventKitCalendarStore())
                    .list(from: from, to: to, calendarName: calendar)
                Output.emit(items, json: output.json)
            }
        }
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create an event.",
            discussion: "Examples:\n  mac calendar add \"Dentist\" --at \"tomorrow 2pm\" --duration 1h\n  mac calendar add \"Offsite\" --at 2026-09-01 --all-day --calendar Work"
        )

        @Argument(help: "Event title.") var title: String
        @Option(help: "Start time, e.g. 'tomorrow 2pm' or '2026-08-27 14:00'.") var at: String
        @Option(help: "Length, e.g. 1h or 30m (default: 1h).") var duration: String?
        @Option(help: "Target calendar name (default: your default calendar).") var calendar: String?
        @Option(help: "Event location.") var location: String?
        @Option(help: "Event notes.") var notes: String?
        @Flag(name: .customLong("all-day"), help: "Create as an all-day event.") var allDay = false
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let item = try await CalendarActions(store: EventKitCalendarStore())
                    .add(title: title, at: at, duration: duration, calendarName: calendar,
                         location: location, notes: notes, allDay: allDay)
                if output.json || !output.quiet { Output.emit(item, json: output.json) }
            }
        }
    }

    struct Edit: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Edit an event by exact id.",
            discussion: "Get ids from: mac calendar list"
        )

        @Argument(help: "Event id from 'mac calendar list'.") var id: String
        @Option(help: "New title.") var title: String?
        @Option(help: "New start time.") var at: String?
        @Option(help: "New length, e.g. 1h.") var duration: String?
        @Option(help: "New location.") var location: String?
        @Option(help: "New notes.") var notes: String?
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let item = try await CalendarActions(store: EventKitCalendarStore())
                    .edit(id: id, title: title, at: at, duration: duration,
                          location: location, notes: notes)
                if output.json || !output.quiet { Output.emit(item, json: output.json) }
            }
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete an event by exact id.")

        @Argument(help: "Event id from 'mac calendar list'.") var id: String
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                try await CalendarActions(store: EventKitCalendarStore()).delete(id: id)
                Output.emitConfirmation(key: "deleted", value: id, human: "deleted",
                                        json: output.json, quiet: output.quiet)
            }
        }
    }

    struct Calendars: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List available calendars.")

        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let items = try await CalendarActions(store: EventKitCalendarStore()).calendars()
                Output.emit(items, json: output.json)
            }
        }
    }
}
