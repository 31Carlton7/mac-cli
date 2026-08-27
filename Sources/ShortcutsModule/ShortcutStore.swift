import Core
import Foundation

public protocol ShortcutStore {
    func list() async throws -> [ShortcutInfo]
    /// Runs by exact id. Returns the shortcut's textual output ("" when none).
    func run(id: String, input: String?) async throws -> String
}
