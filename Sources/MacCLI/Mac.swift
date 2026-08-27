import ArgumentParser
import CalendarModule
import CallModule
import ContactsModule
import FinderModule
import KeynoteModule
import MailModule
import MessagesModule
import MusicModule
import NotesModule
import RemindersModule
import ShortcutsModule
import TVModule

@main
struct Mac: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mac",
        abstract: "Agent-friendly CLI for native macOS apps (Calendar, Reminders, Contacts, Mail, Messages, Notes, Music, TV, Shortcuts, Call, FaceTime, Finder, Keynote).",
        version: "0.5.0",
        subcommands: [CalendarCommand.self, RemindersCommand.self, ContactsCommand.self, MailCommand.self, MessagesCommand.self, NotesCommand.self, MusicCommand.self, TVCommand.self, ShortcutsCommand.self, CallCommand.self, FaceTimeCommand.self, FinderCommand.self, KeynoteCommand.self, DoctorCommand.self]
    )
}
