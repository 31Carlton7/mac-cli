import ApplicationServices
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
            Self.automationRow("automation:Mail", app: "Mail",
                               bundleID: "com.apple.mail", commandHint: "mail"),
            Self.automationRow("automation:Messages", app: "Messages",
                               bundleID: "com.apple.MobileSMS", commandHint: "messages"),
            Self.automationRow("automation:Notes", app: "Notes",
                               bundleID: "com.apple.Notes", commandHint: "notes"),
            Self.fullDiskAccessRow(),
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

    static func automationRow(_ label: String, app: String, bundleID: String,
                              commandHint: String) -> CapabilityStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false)
        let state = PermissionProbes.automationState(fromStatus: status)
        let fix: String? = switch state {
        case .granted:
            nil
        case .notRequested:
            "Run any `mac \(commandHint)` command to trigger the consent prompt."
        case .unknown:
            "Open \(app) once and re-run mac doctor to determine automation status."
        default:
            "Enable \(app) under System Settings > Privacy & Security > Automation for your terminal app."
        }
        return CapabilityStatus(capability: label, status: state, fixOverride: fix)
    }

    static func fullDiskAccessRow() -> CapabilityStatus {
        let path = NSHomeDirectory() + "/Library/Messages/chat.db"
        let state = PermissionProbes.fullDiskAccessState(probing: path)
        let fix: String? = switch state {
        case .granted:
            nil
        case .denied:
            "Grant Full Disk Access to your terminal app in System Settings > Privacy & Security > Full Disk Access (required to read Messages history)."
        case .unknown:
            "Messages data is not visible — either Messages has never been used on this Mac, or your terminal app lacks Full Disk Access (System Settings > Privacy & Security > Full Disk Access)."
        default:
            nil
        }
        return CapabilityStatus(capability: "fullDiskAccess", status: state, fixOverride: fix)
    }
}
