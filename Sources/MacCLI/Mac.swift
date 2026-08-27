import ArgumentParser
import CalendarModule
import ContactsModule
import MailModule
import MessagesModule
import NotesModule
import RemindersModule

@main
struct Mac: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mac",
        abstract: "Agent-friendly CLI for native macOS apps (Calendar, Reminders, Contacts, Mail, Messages, Notes).",
        version: "0.3.0",
        subcommands: [CalendarCommand.self, RemindersCommand.self, ContactsCommand.self, MailCommand.self, MessagesCommand.self, NotesCommand.self, DoctorCommand.self]
    )
}
