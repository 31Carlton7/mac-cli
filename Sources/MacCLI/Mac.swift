import ArgumentParser
import CalendarModule
import ContactsModule
import MailModule
import RemindersModule

@main
struct Mac: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mac",
        abstract: "Agent-friendly CLI for native macOS apps (Calendar, Reminders, Contacts, Mail).",
        version: "0.1.0",
        subcommands: [CalendarCommand.self, RemindersCommand.self, ContactsCommand.self, MailCommand.self, DoctorCommand.self]
    )
}
