import ArgumentParser
import Core
import Foundation

public struct RemindersCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "reminders",
        abstract: "Read and write Reminders.",
        subcommands: [List.self, Add.self, Complete.self, Edit.self, Delete.self, Lists.self]
    )

    public init() {}

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List reminders (incomplete only by default).",
            discussion: "Examples:\n  mac reminders list\n  mac reminders list --list Groceries --due-before friday --json"
        )

        @Option(help: "Only this reminder list.") var list: String?
        @Flag(name: .customLong("include-completed"), help: "Include completed reminders.")
        var includeCompleted = false
        @Option(name: .customLong("due-before"), help: "Only reminders due before this date.")
        var dueBefore: String?
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let items = try await ReminderActions(store: EventKitReminderStore())
                    .list(listName: list, includeCompleted: includeCompleted, dueBefore: dueBefore)
                Output.emit(items, json: output.json)
            }
        }
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create a reminder.",
            discussion: "Examples:\n  mac reminders add \"Buy milk\" --list Groceries --due \"tomorrow 9am\"\n  mac reminders add \"File taxes\" --priority high"
        )

        @Argument(help: "Reminder title.") var title: String
        @Option(help: "Target list name (default: your default list).") var list: String?
        @Option(help: "Due date, e.g. 'tomorrow 9am'.") var due: String?
        @Option(help: "Reminder notes.") var notes: String?
        @Option(help: "Priority: none, low, medium, or high.") var priority: ReminderPriority = .none
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let item = try await ReminderActions(store: EventKitReminderStore())
                    .add(title: title, listName: list, due: due, notes: notes, priority: priority)
                if !output.quiet { Output.emit(item, json: output.json) }
            }
        }
    }

    struct Complete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Mark a reminder complete by exact id.")

        @Argument(help: "Reminder id from 'mac reminders list'.") var id: String
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let item = try await ReminderActions(store: EventKitReminderStore()).complete(id: id)
                if !output.quiet { Output.emit(item, json: output.json) }
            }
        }
    }

    struct Edit: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Edit a reminder by exact id.")

        @Argument(help: "Reminder id from 'mac reminders list'.") var id: String
        @Option(help: "New title.") var title: String?
        @Option(help: "New due date.") var due: String?
        @Option(help: "New notes.") var notes: String?
        @Option(help: "New priority: none, low, medium, or high.") var priority: ReminderPriority?
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let item = try await ReminderActions(store: EventKitReminderStore())
                    .edit(id: id, title: title, due: due, notes: notes, priority: priority)
                if !output.quiet { Output.emit(item, json: output.json) }
            }
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a reminder by exact id.")

        @Argument(help: "Reminder id from 'mac reminders list'.") var id: String
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                try await ReminderActions(store: EventKitReminderStore()).delete(id: id)
                if output.json {
                    print(#"{"deleted":"\#(id)"}"#)
                } else if !output.quiet {
                    print("deleted \(id)")
                }
            }
        }
    }

    struct Lists: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List available reminder lists.")

        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let items = try await ReminderActions(store: EventKitReminderStore()).lists()
                Output.emit(items, json: output.json)
            }
        }
    }
}
