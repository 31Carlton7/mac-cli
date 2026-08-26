import ArgumentParser
import Core
import Foundation

public struct ContactsCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "contacts",
        abstract: "Read and write Contacts.",
        subcommands: [Find.self, Show.self, Add.self, Edit.self, Delete.self]
    )

    public init() {}

    struct Find: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Search contacts by name, email, or phone.",
            discussion: "Examples:\n  mac contacts find \"Sarah\"\n  mac contacts find sarah@example.com --json"
        )

        @Argument(help: "Name, email, or phone substring to search for.") var query: String
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let items = try await ContactActions(store: CNContactStoreAdapter()).find(query: query)
                Output.emit(items, json: output.json)
            }
        }
    }

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show a full contact card by exact id.")

        @Argument(help: "Contact id from 'mac contacts find'.") var id: String
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let item = try await ContactActions(store: CNContactStoreAdapter()).show(id: id)
                Output.emit(item, json: output.json)
            }
        }
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create a contact.",
            discussion: "Example:\n  mac contacts add --name \"Sarah Chen\" --email sarah@example.com --phone +15551234567"
        )

        @Option(help: "Full name (required).") var name: String
        @Option(help: "Phone number.") var phone: String?
        @Option(help: "Email address.") var email: String?
        @Option(name: .customLong("org"), help: "Organization.") var organization: String?
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let item = try await ContactActions(store: CNContactStoreAdapter())
                    .add(name: name, phone: phone, email: email, organization: organization)
                if output.json || !output.quiet { Output.emit(item, json: output.json) }
            }
        }
    }

    struct Edit: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Edit a contact by exact id.",
            discussion: "--name and --org replace; --phone and --email append."
        )

        @Argument(help: "Contact id from 'mac contacts find'.") var id: String
        @Option(help: "New full name (replaces).") var name: String?
        @Option(help: "Phone number to append.") var phone: String?
        @Option(help: "Email address to append.") var email: String?
        @Option(name: .customLong("org"), help: "New organization (replaces).") var organization: String?
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let item = try await ContactActions(store: CNContactStoreAdapter())
                    .edit(id: id, name: name, phone: phone, email: email, organization: organization)
                if output.json || !output.quiet { Output.emit(item, json: output.json) }
            }
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a contact by exact id.")

        @Argument(help: "Contact id from 'mac contacts find'.") var id: String
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                try await ContactActions(store: CNContactStoreAdapter()).delete(id: id)
                Output.emitConfirmation(key: "deleted", value: id, human: "deleted",
                                        json: output.json, quiet: output.quiet)
            }
        }
    }
}
