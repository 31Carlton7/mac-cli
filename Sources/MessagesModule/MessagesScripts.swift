import Core
import Foundation

/// Pure AppleScript source builders for Messages operations. These functions
/// only produce strings — nothing here executes a script. Every user-supplied
/// value MUST be routed through `AppleScript.escape` before interpolation.
enum MessagesScripts {
    static func send(handle: String, text: String) -> String {
        """
        tell application "Messages"
            set svc to 1st account whose service type = iMessage
            send "\(AppleScript.escape(text))" to participant "\(AppleScript.escape(handle))" of svc
        end tell
        return "ok"
        """
    }
}
