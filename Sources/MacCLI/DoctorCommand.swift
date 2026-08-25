import ArgumentParser
import Contacts
import Core
import EventKit

struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Audit TCC permissions and print exact fix steps.",
        discussion: "Checking status never triggers a permission prompt. Exit code is always 0."
    )

    @OptionGroup var output: OutputOptions

    func run() async {
        Output.emit([
            CapabilityStatus(capability: "calendar",
                             status: Self.state(EKEventStore.authorizationStatus(for: .event)),
                             pane: "Calendars"),
            CapabilityStatus(capability: "reminders",
                             status: Self.state(EKEventStore.authorizationStatus(for: .reminder)),
                             pane: "Reminders"),
            CapabilityStatus(capability: "contacts",
                             status: Self.contactsState(),
                             pane: "Contacts"),
        ], json: output.json)
    }

    static func state(_ status: EKAuthorizationStatus) -> AuthState {
        switch status {
        case .fullAccess: .granted
        case .writeOnly: .writeOnly
        case .notDetermined: .notRequested
        default: .denied
        }
    }

    static func contactsState() -> AuthState {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: .granted
        case .notDetermined: .notRequested
        default: .denied
        }
    }
}
