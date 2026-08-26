# mac-cli v2 (Mail + Messages) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `mac mail` (read/search/triage/draft/send via Mail.app AppleScript) and `mac messages` (read via chat.db SQLite, send via Messages AppleScript), with doctor coverage for Automation consent and Full Disk Access.

**Architecture:** Two new modules following the shipped v1 pattern (store protocol → mock-tested actions → real adapter → subcommands). Core gains an `AppleScript` runner (pure string builders + NSAppleScript execution + error mapping) and three messaging models. Messages reads come from a read-only SQLite reader over `~/Library/Messages/chat.db`; everything else is AppleScript.

**Tech Stack:** Swift 5.9+, swift-argument-parser, NSAppleScript (Foundation), SQLite3 (system C module), ApplicationServices (AEDeterminePermissionToAutomateTarget), XCTest. macOS 14+.

**Conventions (all tasks, carried from v1):**
- Exit codes 0/1/2 (+64 usage); mutations by exact ID; `--json` always prints, `--quiet` silences human output only; JSON sorted keys + ISO 8601 + nil-omitting, locked by exact-string tests.
- TDD: tests first, observe the failure, implement, observe the pass. Fix implementations, not expectations; report BLOCKED if an expectation seems wrong.
- Every commit message ends with the trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` on its own line.
- NEVER run live `mac mail`/`mac messages` data commands during implementation (Automation/FDA auto-deny in agent shells; live verification is the user-run smoke test). `swift test`, `swift build`, and `--help` are always safe.
- Working directory: `/Users/carltonaikins/Desktop/Home/Work/Projects/mac-cli`, branch `v2` (create from `main` before Task 1: `git checkout -b v2`).

Baseline: 56 tests green on `main`.

---

### Task 1: Core — AppleScript escaping, record parsing, runner, error mapping

**Files:**
- Create: `Sources/Core/AppleScriptRunner.swift`
- Modify: `Sources/MacCLI/Info.plist` (add one key)
- Test: `Tests/CoreTests/AppleScriptRunnerTests.swift`

- [ ] **Step 1: Write the failing tests** — `Tests/CoreTests/AppleScriptRunnerTests.swift`

```swift
import XCTest
@testable import Core

final class AppleScriptRunnerTests: XCTestCase {
    func testEscape() {
        XCTAssertEqual(AppleScript.escape(#"say "hi""#), #"say \"hi\""#)
        XCTAssertEqual(AppleScript.escape(#"back\slash"#), #"back\\slash"#)
        XCTAssertEqual(AppleScript.escape("line1\nline2"), #"line1\nline2"#)
        XCTAssertEqual(AppleScript.escape("cr\rend"), #"cr\rend"#)
        XCTAssertEqual(AppleScript.escape(#"both \ and " here"#), #"both \\ and \" here"#)
    }

    func testParseRecords() {
        XCTAssertEqual(AppleScript.parseRecords(""), [])
        let one = "a\u{1F}b\u{1F}c"
        XCTAssertEqual(AppleScript.parseRecords(one), [["a", "b", "c"]])
        let two = "a\u{1F}b\u{1E}c\u{1F}d"
        XCTAssertEqual(AppleScript.parseRecords(two), [["a", "b"], ["c", "d"]])
    }

    func testRunnerExecutesPlainScript() async throws {
        let result = try await AppleScript.run(#"return "ok""#, targetName: "Test")
        XCTAssertEqual(result, "ok")
    }

    func testMapErrorAutomationDenied() {
        let info: NSDictionary = [NSAppleScript.errorNumber: -1743,
                                  NSAppleScript.errorMessage: "Not authorized."]
        let error = AppleScript.mapError(info, targetName: "Mail")
        guard let mac = error as? MacError else { return XCTFail("expected MacError") }
        XCTAssertEqual(mac.code, .permissionDenied)
        XCTAssertTrue(mac.message.contains("Automation"))
        XCTAssertTrue(mac.message.contains("mac doctor"))
    }

    func testMapErrorUnknownStaysGeneric() {
        let info: NSDictionary = [NSAppleScript.errorNumber: -1728,
                                  NSAppleScript.errorMessage: "Can't get message."]
        let error = AppleScript.mapError(info, targetName: "Mail")
        XCTAssertFalse(error is MacError)
        XCTAssertTrue(error.localizedDescription.contains("Can't get message."))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AppleScriptRunnerTests`
Expected: compile FAILURE — `cannot find 'AppleScript' in scope`

- [ ] **Step 3: Implement** — `Sources/Core/AppleScriptRunner.swift`

```swift
import Foundation

public enum AppleScript {
    /// ASCII unit/record separators used by generated scripts to delimit output.
    public static let fieldSep = "\u{1F}"
    public static let recordSep = "\u{1E}"

    /// Escapes a value for embedding inside an AppleScript string literal.
    /// This is the injection surface — every user-supplied value MUST pass through it.
    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    /// Inverse of the separators generated scripts join with. Empty output -> [].
    public static func parseRecords(_ output: String) -> [[String]] {
        guard !output.isEmpty else { return [] }
        return output.components(separatedBy: recordSep).map {
            $0.components(separatedBy: fieldSep)
        }
    }

    /// Runs a script and returns its string result. NSAppleScript is main-thread-only.
    @MainActor
    public static func run(_ source: String, targetName: String) throws -> String {
        guard let script = NSAppleScript(source: source) else {
            throw MacError(.badInput, "Could not compile AppleScript.")
        }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            throw mapError(errorInfo, targetName: targetName)
        }
        return result.stringValue ?? ""
    }

    /// -1743 (Automation consent denied) -> permissionDenied MacError.
    /// Everything else -> plain NSError so withErrorHandling emits the internal envelope.
    static func mapError(_ info: NSDictionary, targetName: String) -> Error {
        let number = (info[NSAppleScript.errorNumber] as? Int) ?? 0
        let message = (info[NSAppleScript.errorMessage] as? String) ?? "AppleScript error \(number)"
        if number == -1743 {
            return MacError(.permissionDenied, "\(targetName) automation not granted. Enable \(targetName) under System Settings > Privacy & Security > Automation for your terminal app, or run: mac doctor")
        }
        return NSError(domain: "AppleScript", code: number,
                       userInfo: [NSLocalizedDescriptionKey: "\(targetName): \(message)"])
    }
}
```

- [ ] **Step 4: Add the Automation usage description** — in `Sources/MacCLI/Info.plist`, add inside the `<dict>`:

```xml
    <key>NSAppleEventsUsageDescription</key>
    <string>mac-cli controls Mail and Messages on your behalf.</string>
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter AppleScriptRunnerTests`
Expected: PASS (5 tests). Full `swift test`: 61 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: add AppleScript runner with escaping, record parsing, and error mapping"
```

---

### Task 2: Core — messaging models with locked JSON schemas

**Files:**
- Create: `Sources/Core/MessagingModels.swift`
- Test: `Tests/CoreTests/MessagingModelsTests.swift`

- [ ] **Step 1: Write the failing tests** — `Tests/CoreTests/MessagingModelsTests.swift`

```swift
import XCTest
@testable import Core

final class MessagingModelsTests: XCTestCase {
    let when = Date(timeIntervalSince1970: 1_787_824_800) // 2026-08-27T10:00:00Z

    func testEmailItemJSONSchema() throws {
        let email = EmailItem(id: "<m1@x>", subject: "Invoice", from: "a@b.com",
                              date: when, isRead: false, account: "Work", body: nil)
        let json = String(data: try Output.encoder.encode(email), encoding: .utf8)!
        XCTAssertEqual(json, #"{"account":"Work","date":"2026-08-27T10:00:00Z","from":"a@b.com","id":"<m1@x>","isRead":false,"subject":"Invoice"}"#)
    }

    func testEmailItemBodyIncludedWhenPresent() throws {
        let email = EmailItem(id: "<m1@x>", subject: "s", from: "f", date: when,
                              isRead: true, account: "A", body: "hello")
        let json = String(data: try Output.encoder.encode(email), encoding: .utf8)!
        XCTAssertTrue(json.contains(#""body":"hello""#))
    }

    func testMessageItemJSONSchema() throws {
        let message = MessageItem(id: "g1", chat: "+15551234567", sender: "+15551234567",
                                  text: "hey", date: when, isFromMe: false)
        let json = String(data: try Output.encoder.encode(message), encoding: .utf8)!
        XCTAssertEqual(json, #"{"chat":"+15551234567","date":"2026-08-27T10:00:00Z","id":"g1","isFromMe":false,"sender":"+15551234567","text":"hey"}"#)
    }

    func testConversationInfoJSONSchema() throws {
        let convo = ConversationInfo(id: "c1", name: "Sarah Chen", lastActivity: when, isGroup: false)
        let json = String(data: try Output.encoder.encode(convo), encoding: .utf8)!
        XCTAssertEqual(json, #"{"id":"c1","isGroup":false,"lastActivity":"2026-08-27T10:00:00Z","name":"Sarah Chen"}"#)
    }

    func testHumanLines() {
        let email = EmailItem(id: "<m1@x>", subject: "Invoice", from: "a@b.com",
                              date: when, isRead: false, account: "Work", body: nil)
        XCTAssertTrue(email.humanLine.hasPrefix("<m1@x>  Invoice  a@b.com  "))
        XCTAssertTrue(email.humanLine.hasSuffix("[unread]"))
        let message = MessageItem(id: "g1", chat: "c", sender: "me", text: "hey", date: when, isFromMe: true)
        XCTAssertTrue(message.humanLine.hasSuffix("me: hey"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MessagingModelsTests`
Expected: compile FAILURE — `cannot find 'EmailItem' in scope`

- [ ] **Step 3: Implement** — `Sources/Core/MessagingModels.swift`

```swift
import Foundation

public struct EmailItem: Codable, Equatable, HumanRenderable {
    public let id: String
    public let subject: String
    public let from: String
    public let date: Date
    public let isRead: Bool
    public let account: String
    public let body: String?

    public init(id: String, subject: String, from: String, date: Date,
                isRead: Bool, account: String, body: String?) {
        self.id = id
        self.subject = subject
        self.from = from
        self.date = date
        self.isRead = isRead
        self.account = account
        self.body = body
    }

    public var humanLine: String {
        let unread = isRead ? "" : "  [unread]"
        return "\(id)  \(subject)  \(from)  \(humanDate.string(from: date))\(unread)"
    }
}

public struct MessageItem: Codable, Equatable, HumanRenderable {
    public let id: String
    public let chat: String
    public let sender: String
    public let text: String
    public let date: Date
    public let isFromMe: Bool

    public init(id: String, chat: String, sender: String, text: String,
                date: Date, isFromMe: Bool) {
        self.id = id
        self.chat = chat
        self.sender = sender
        self.text = text
        self.date = date
        self.isFromMe = isFromMe
    }

    public var humanLine: String { "\(humanDate.string(from: date))  \(sender): \(text)" }
}

public struct ConversationInfo: Codable, Equatable, HumanRenderable {
    public let id: String
    public let name: String
    public let lastActivity: Date
    public let isGroup: Bool

    public init(id: String, name: String, lastActivity: Date, isGroup: Bool) {
        self.id = id
        self.name = name
        self.lastActivity = lastActivity
        self.isGroup = isGroup
    }

    public var humanLine: String {
        let group = isGroup ? "  [group]" : ""
        return "\(id)  \(name)  \(humanDate.string(from: lastActivity))\(group)"
    }
}
```

(`humanDate` is the existing internal formatter in `Sources/Core/Models.swift` — same module, accessible.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MessagingModelsTests`
Expected: PASS (5 tests). Full suite: 66 tests.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: add EmailItem, MessageItem, and ConversationInfo models"
```

---

### Task 3: Doctor v2 — automation and Full Disk Access probes

**Files:**
- Create: `Sources/Core/PermissionProbes.swift`
- Modify: `Sources/Core/CapabilityStatus.swift` (add one init)
- Modify: `Sources/MacCLI/DoctorCommand.swift`
- Test: `Tests/CoreTests/PermissionProbesTests.swift`

- [ ] **Step 1: Write the failing tests** — `Tests/CoreTests/PermissionProbesTests.swift`

```swift
import XCTest
@testable import Core

final class PermissionProbesTests: XCTestCase {
    func testAutomationStateMapping() {
        XCTAssertEqual(PermissionProbes.automationState(fromStatus: 0), .granted)
        XCTAssertEqual(PermissionProbes.automationState(fromStatus: -1744), .notRequested) // would prompt
        XCTAssertEqual(PermissionProbes.automationState(fromStatus: -600), .notRequested)  // app not running
        XCTAssertEqual(PermissionProbes.automationState(fromStatus: -1743), .denied)
    }

    func testFullDiskAccessProbe() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-cli-fda-test")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let readable = dir.appendingPathComponent("chat.db")
        try Data("x".utf8).write(to: readable)
        XCTAssertEqual(PermissionProbes.fullDiskAccessState(probing: readable.path), .granted)
        XCTAssertEqual(PermissionProbes.fullDiskAccessState(probing: dir.appendingPathComponent("missing.db").path), .denied)
    }

    func testCapabilityStatusFixOverride() throws {
        let status = CapabilityStatus(capability: "automation:Mail", status: .denied,
                                      fixOverride: "Enable Mail under Automation.")
        XCTAssertEqual(status.fix, "Enable Mail under Automation.")
        XCTAssertEqual(status.humanLine, "automation:Mail: denied  — Enable Mail under Automation.")
        let granted = CapabilityStatus(capability: "fullDiskAccess", status: .granted, fixOverride: nil)
        let json = String(data: try Output.encoder.encode(granted), encoding: .utf8)!
        XCTAssertEqual(json, #"{"capability":"fullDiskAccess","status":"granted"}"#)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PermissionProbesTests`
Expected: compile FAILURE — `cannot find 'PermissionProbes' in scope`

- [ ] **Step 3: Implement the probes** — `Sources/Core/PermissionProbes.swift`

```swift
import Foundation

public enum PermissionProbes {
    /// Maps an AEDeterminePermissionToAutomateTarget OSStatus to an AuthState.
    /// 0 granted; -1744 would-prompt and -600 target-not-running both mean
    /// consent hasn't been decided yet; anything else is denied.
    public static func automationState(fromStatus status: Int32) -> AuthState {
        switch status {
        case 0: .granted
        case -1744, -600: .notRequested
        default: .denied
        }
    }

    /// Full Disk Access has no query API; it is granted iff the protected path is readable.
    public static func fullDiskAccessState(probing path: String) -> AuthState {
        FileManager.default.isReadableFile(atPath: path) ? .granted : .denied
    }
}
```

And in `Sources/Core/CapabilityStatus.swift`, add this second initializer to the struct (leave the existing init untouched):

```swift
    /// For capabilities whose fix text doesn't follow the pane template.
    public init(capability: String, status: AuthState, fixOverride: String?) {
        self.capability = capability
        self.status = status
        self.fix = fixOverride
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PermissionProbesTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Wire the new rows into doctor** — `Sources/MacCLI/DoctorCommand.swift`

Add `import ApplicationServices` at the top. Append these three rows to the array in `run()` (after the contacts row):

```swift
            Self.automationRow("automation:Mail", app: "Mail",
                               bundleID: "com.apple.mail", commandHint: "mail"),
            Self.automationRow("automation:Messages", app: "Messages",
                               bundleID: "com.apple.MobileSMS", commandHint: "messages"),
            Self.fullDiskAccessRow(),
```

And add these static helpers to `DoctorCommand`:

```swift
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
        default:
            "Enable \(app) under System Settings > Privacy & Security > Automation for your terminal app."
        }
        return CapabilityStatus(capability: label, status: state, fixOverride: fix)
    }

    static func fullDiskAccessRow() -> CapabilityStatus {
        let path = NSHomeDirectory() + "/Library/Messages/chat.db"
        let state = PermissionProbes.fullDiskAccessState(probing: path)
        let fix = state == .granted ? nil
            : "Grant Full Disk Access to your terminal app in System Settings > Privacy & Security > Full Disk Access (required to read Messages history)."
        return CapabilityStatus(capability: "fullDiskAccess", status: state, fixOverride: fix)
    }
```

- [ ] **Step 6: Build and verify live** (doctor never prompts — safe)

Run: `swift build && swift run mac doctor`
Expected: six rows now — the original three plus `automation:Mail`, `automation:Messages`, `fullDiskAccess`, each with a sensible state and fix hint. Exit 0. `swift run mac doctor --json` emits six objects.

Run: `swift test`
Expected: 69 tests, 0 failures.

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "feat: extend mac doctor with automation and Full Disk Access checks"
```

---

### Task 4: MailModule — store protocol, actions, mock-backed tests

**Files:**
- Create: `Sources/MailModule/MailStore.swift`
- Create: `Sources/MailModule/MailActions.swift`
- Create: `Sources/MailModule/MailModule.swift` (placeholder comment: `// MailModule: AppleScript-backed Mail store and subcommands.`)
- Modify: `Package.swift` (add MailModule target + test target)
- Test: `Tests/MailModuleTests/MailActionsTests.swift`

- [ ] **Step 1: Add targets to Package.swift**

In `targets:`, after the ContactsModule entry add:

```swift
        .target(name: "MailModule", dependencies: ["Core"]),
```

Add `"MailModule"` to the MacCLI executable target's dependencies array. After the ContactsModuleTests entry add:

```swift
        .testTarget(name: "MailModuleTests", dependencies: ["MailModule"]),
```

- [ ] **Step 2: Write the store protocol** — `Sources/MailModule/MailStore.swift`

```swift
import Core
import Foundation

public struct MailDraft: Equatable {
    public var to: String
    public var cc: String?
    public var subject: String
    public var body: String

    public init(to: String, cc: String?, subject: String, body: String) {
        self.to = to
        self.cc = cc
        self.subject = subject
        self.body = body
    }
}

public protocol MailStore {
    func unread(account: String?, limit: Int) async throws -> [EmailItem]
    func search(_ query: String, limit: Int) async throws -> [EmailItem]
    func read(id: String) async throws -> EmailItem
    func draft(_ draft: MailDraft) async throws
    func send(_ draft: MailDraft) async throws
    func markRead(id: String) async throws
    func archive(id: String) async throws
}
```

- [ ] **Step 3: Write the failing tests** — `Tests/MailModuleTests/MailActionsTests.swift`

```swift
import XCTest
import Core
@testable import MailModule

final class MockMailStore: MailStore {
    var accessGranted = true
    var emails: [EmailItem] = []
    var drafted: [MailDraft] = []
    var sent: [MailDraft] = []
    var archivedIDs: [String] = []

    private func gate() throws {
        if !accessGranted {
            throw MacError(.permissionDenied, "Mail automation not granted. Run: mac doctor")
        }
    }

    func unread(account: String?, limit: Int) async throws -> [EmailItem] {
        try gate()
        return emails.filter { !$0.isRead && (account == nil || $0.account == account) }.prefix(limit).map { $0 }
    }

    func search(_ query: String, limit: Int) async throws -> [EmailItem] {
        try gate()
        let q = query.lowercased()
        return emails.filter { $0.subject.lowercased().contains(q) || $0.from.lowercased().contains(q) }
            .prefix(limit).map { $0 }
    }

    func read(id: String) async throws -> EmailItem {
        try gate()
        guard let item = emails.first(where: { $0.id == id }) else {
            throw MacError(.notFound, "No message with id \(id).")
        }
        return item
    }

    func draft(_ draft: MailDraft) async throws { try gate(); drafted.append(draft) }
    func send(_ draft: MailDraft) async throws { try gate(); sent.append(draft) }

    func markRead(id: String) async throws {
        try gate()
        guard emails.contains(where: { $0.id == id }) else {
            throw MacError(.notFound, "No message with id \(id).")
        }
    }

    func archive(id: String) async throws {
        try gate()
        guard emails.contains(where: { $0.id == id }) else {
            throw MacError(.notFound, "No message with id \(id).")
        }
        archivedIDs.append(id)
    }
}

final class MailActionsTests: XCTestCase {
    var store = MockMailStore()
    lazy var actions = MailActions(store: store)
    let when = Date(timeIntervalSince1970: 1_787_824_800)

    func email(_ id: String, subject: String = "s", read: Bool = false) -> EmailItem {
        EmailItem(id: id, subject: subject, from: "a@b.com", date: when,
                  isRead: read, account: "Work", body: nil)
    }

    func testUnreadFiltersAndLimits() async throws {
        store.emails = [email("1"), email("2", read: true), email("3")]
        let items = try await actions.unread(account: nil, limit: 20)
        XCTAssertEqual(items.map(\.id), ["1", "3"])
    }

    func testEmptySearchQueryThrowsBadInput() async {
        do {
            _ = try await actions.search(query: "  ", limit: 20)
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
        } catch { XCTFail("wrong error type") }
    }

    func testLimitOutOfRangeThrowsBadInput() async {
        do {
            _ = try await actions.unread(account: nil, limit: 0)
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
        } catch { XCTFail("wrong error type") }
    }

    func testComposeRequiresValidRecipient() async {
        do {
            try await actions.compose(to: "not-an-email", cc: nil, subject: "s", body: "b", send: true)
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
        } catch { XCTFail("wrong error type") }
    }

    func testComposeRequiresSubjectOrBody() async {
        do {
            try await actions.compose(to: "a@b.com", cc: nil, subject: "", body: "  ", send: false)
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
        } catch { XCTFail("wrong error type") }
    }

    func testComposeRoutesDraftVsSend() async throws {
        try await actions.compose(to: "a@b.com", cc: nil, subject: "s", body: "b", send: false)
        try await actions.compose(to: "a@b.com", cc: "c@d.com", subject: "s", body: "b", send: true)
        XCTAssertEqual(store.drafted.count, 1)
        XCTAssertEqual(store.sent.count, 1)
        XCTAssertEqual(store.sent[0].cc, "c@d.com")
    }

    func testReadUnknownIDThrowsNotFound() async {
        do {
            _ = try await actions.read(id: "nope")
            XCTFail("expected notFound")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .notFound)
        } catch { XCTFail("wrong error type") }
    }

    func testPermissionDeniedPropagates() async {
        store.accessGranted = false
        do {
            _ = try await actions.unread(account: nil, limit: 5)
            XCTFail("expected permissionDenied")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .permissionDenied)
        } catch { XCTFail("wrong error type") }
    }
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `swift test --filter MailActionsTests`
Expected: compile FAILURE — `cannot find 'MailActions' in scope`

- [ ] **Step 5: Implement** — `Sources/MailModule/MailActions.swift`

```swift
import Core
import Foundation

public struct MailActions {
    let store: MailStore

    public init(store: MailStore) {
        self.store = store
    }

    public func unread(account: String?, limit: Int) async throws -> [EmailItem] {
        try validate(limit: limit)
        return try await store.unread(account: account, limit: limit)
    }

    public func search(query: String, limit: Int) async throws -> [EmailItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw MacError(.badInput, "Search query cannot be empty.")
        }
        try validate(limit: limit)
        return try await store.search(trimmed, limit: limit)
    }

    public func read(id: String) async throws -> EmailItem {
        try await store.read(id: id)
    }

    public func compose(to: String, cc: String?, subject: String, body: String,
                        send: Bool) async throws {
        let recipient = to.trimmingCharacters(in: .whitespaces)
        guard recipient.contains("@"), recipient.count >= 3 else {
            throw MacError(.badInput, "--to must be an email address, got '\(to)'.")
        }
        let hasContent = !subject.trimmingCharacters(in: .whitespaces).isEmpty
            || !body.trimmingCharacters(in: .whitespaces).isEmpty
        guard hasContent else {
            throw MacError(.badInput, "Provide at least one of --subject or --body.")
        }
        let draft = MailDraft(to: recipient, cc: cc, subject: subject, body: body)
        if send {
            try await store.send(draft)
        } else {
            try await store.draft(draft)
        }
    }

    public func markRead(id: String) async throws {
        try await store.markRead(id: id)
    }

    public func archive(id: String) async throws {
        try await store.archive(id: id)
    }

    func validate(limit: Int) throws {
        guard (1...200).contains(limit) else {
            throw MacError(.badInput, "--limit must be between 1 and 200.")
        }
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter MailActionsTests`
Expected: PASS (8 tests). Full suite: 77 tests.

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "feat: add MailStore protocol and mock-tested MailActions"
```

---

### Task 5: MailModule — AppleScript builders

**Files:**
- Create: `Sources/MailModule/MailScripts.swift`
- Test: `Tests/MailModuleTests/MailScriptsTests.swift`

Builders are pure functions returning complete AppleScript source. Output protocol: records joined by `character id 30`, fields by `character id 31`; dates emitted as `yyyy-MM-ddTHH:mm:ss` via shared helpers. Not-found paths return the sentinel `NOTFOUND`; archive-mailbox-missing returns `NOARCHIVE:<account>`.

- [ ] **Step 1: Write the failing tests** — `Tests/MailModuleTests/MailScriptsTests.swift`

Tests assert the structurally critical content (escaped payloads, sentinels, clauses) rather than full 30-line script equality — the scripts are deterministic, and escaping is the correctness-critical part.

```swift
import XCTest
@testable import MailModule

final class MailScriptsTests: XCTestCase {
    func testUnreadScriptStructure() {
        let script = MailScripts.unread(account: nil, limit: 20)
        XCTAssertTrue(script.contains("read status is false"))
        XCTAssertTrue(script.contains("is greater than or equal to 20"))
        XCTAssertTrue(script.contains("character id 31"))
        XCTAssertTrue(script.contains("character id 30"))
        XCTAssertFalse(script.contains("acctName is not")) // no account filter when account is nil
    }

    func testUnreadScriptEscapesAccountFilter() {
        let script = MailScripts.unread(account: #"Wo"rk"#, limit: 5)
        XCTAssertTrue(script.contains(#"Wo\"rk"#))
    }

    func testSearchScriptContainsEscapedQueryInBothClauses() {
        let script = MailScripts.search(query: #"inv"oice"#, limit: 10)
        XCTAssertEqual(script.components(separatedBy: #"inv\"oice"#).count - 1, 2) // subject + sender
    }

    func testReadScriptHasSentinelAndBody() {
        let script = MailScripts.read(id: "<m1@x>")
        XCTAssertTrue(script.contains("NOTFOUND"))
        XCTAssertTrue(script.contains(#"message id is "<m1@x>""#))
        XCTAssertTrue(script.contains("content of m"))
    }

    func testComposeScriptEscapesAndRoutes() {
        let draft = MailDraft(to: "a@b.com", cc: "c@d.com",
                              subject: #"He said "hi""#, body: "line1\nline2")
        let asDraft = MailScripts.compose(draft, send: false)
        XCTAssertTrue(asDraft.contains(#"He said \"hi\""#))
        XCTAssertTrue(asDraft.contains(#"line1\nline2"#))
        XCTAssertTrue(asDraft.contains("visible:true"))
        XCTAssertTrue(asDraft.contains("cc recipient"))
        XCTAssertFalse(asDraft.contains("send msg"))
        let asSend = MailScripts.compose(draft, send: true)
        XCTAssertTrue(asSend.contains("send msg"))
        XCTAssertTrue(asSend.contains("visible:false"))
    }

    func testArchiveScriptSentinels() {
        let script = MailScripts.archive(id: "<m1@x>")
        XCTAssertTrue(script.contains("NOTFOUND"))
        XCTAssertTrue(script.contains("NOARCHIVE:"))
        XCTAssertTrue(script.contains(#"mailbox "Archive""#))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MailScriptsTests`
Expected: compile FAILURE — `cannot find 'MailScripts' in scope`

- [ ] **Step 3: Implement** — `Sources/MailModule/MailScripts.swift`

```swift
import Core
import Foundation

enum MailScripts {
    static let prologue = """
    set FS to character id 31
    set RS to character id 30
    on fmt(n)
        set t to n as text
        if (length of t) < 2 then set t to "0" & t
        return t
    end fmt
    on isoDate(d)
        return ((year of d) as text) & "-" & my fmt((month of d) as integer) & "-" & my fmt(day of d) & "T" & my fmt(hours of d) & ":" & my fmt(minutes of d) & ":" & my fmt(seconds of d)
    end isoDate
    """

    static func unread(account: String?, limit: Int) -> String {
        let filter = account.map {
            "if acctName is not \"\(AppleScript.escape($0))\" then set skip to true"
        } ?? ""
        return """
        \(prologue)
        set out to {}
        set n to 0
        tell application "Mail"
            set msgs to (messages of inbox whose read status is false)
            repeat with m in msgs
                set skip to false
                set acctName to ""
                try
                    set acctName to name of account of mailbox of m
                end try
                \(filter)
                if not skip then
                    set rec to (message id of m) & FS & (subject of m) & FS & ((sender of m) as text) & FS & (my isoDate(date received of m)) & FS & "0" & FS & acctName
                    copy rec to end of out
                    set n to n + 1
                    if n is greater than or equal to \(limit) then exit repeat
                end if
            end repeat
        end tell
        set AppleScript's text item delimiters to RS
        return out as text
        """
    }

    static func search(query: String, limit: Int) -> String {
        let q = AppleScript.escape(query)
        return """
        \(prologue)
        set out to {}
        set n to 0
        tell application "Mail"
            set msgs to (messages of inbox whose subject contains "\(q)" or sender contains "\(q)")
            repeat with m in msgs
                set acctName to ""
                try
                    set acctName to name of account of mailbox of m
                end try
                set rflag to "0"
                if read status of m then set rflag to "1"
                set rec to (message id of m) & FS & (subject of m) & FS & ((sender of m) as text) & FS & (my isoDate(date received of m)) & FS & rflag & FS & acctName
                copy rec to end of out
                set n to n + 1
                if n is greater than or equal to \(limit) then exit repeat
            end repeat
        end tell
        set AppleScript's text item delimiters to RS
        return out as text
        """
    }

    static func read(id: String) -> String {
        """
        \(prologue)
        tell application "Mail"
            try
                set m to (first message of inbox whose message id is "\(AppleScript.escape(id))")
            on error
                return "NOTFOUND"
            end try
            set acctName to ""
            try
                set acctName to name of account of mailbox of m
            end try
            set rflag to "0"
            if read status of m then set rflag to "1"
            set rec to (message id of m) & FS & (subject of m) & FS & ((sender of m) as text) & FS & (my isoDate(date received of m)) & FS & rflag & FS & acctName & FS & (content of m)
        end tell
        return rec
        """
    }

    static func compose(_ draft: MailDraft, send: Bool) -> String {
        let cc = draft.cc.map {
            "    tell msg to make new cc recipient with properties {address:\"\(AppleScript.escape($0))\"}"
        } ?? ""
        let finish = send ? "send msg" : "activate"
        return """
        tell application "Mail"
            set msg to make new outgoing message with properties {subject:"\(AppleScript.escape(draft.subject))", content:"\(AppleScript.escape(draft.body))", visible:\(send ? "false" : "true")}
            tell msg to make new to recipient with properties {address:"\(AppleScript.escape(draft.to))"}
        \(cc)
            \(finish)
        end tell
        return "ok"
        """
    }

    static func markRead(id: String) -> String {
        """
        tell application "Mail"
            try
                set m to (first message of inbox whose message id is "\(AppleScript.escape(id))")
            on error
                return "NOTFOUND"
            end try
            set read status of m to true
        end tell
        return "ok"
        """
    }

    static func archive(id: String) -> String {
        """
        tell application "Mail"
            try
                set m to (first message of inbox whose message id is "\(AppleScript.escape(id))")
            on error
                return "NOTFOUND"
            end try
            set acct to account of mailbox of m
            try
                set archiveBox to mailbox "Archive" of acct
            on error
                return "NOARCHIVE:" & (name of acct)
            end try
            move m to archiveBox
        end tell
        return "ok"
        """
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MailScriptsTests`
Expected: PASS (6 tests). Full suite: 83 tests.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: add Mail AppleScript builders with injection-safe escaping"
```

---

### Task 6: MailModule — AppleScript store, subcommands, root wiring

**Files:**
- Create: `Sources/MailModule/AppleScriptMailStore.swift`
- Create: `Sources/MailModule/MailCommand.swift`
- Modify: `Sources/MacCLI/Mac.swift`
- Test: `Tests/MailModuleTests/MailCommandParsingTests.swift`

- [ ] **Step 1: Implement the store** — `Sources/MailModule/AppleScriptMailStore.swift`

```swift
import Core
import Foundation

public final class AppleScriptMailStore: MailStore {
    public init() {}

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    public func unread(account: String?, limit: Int) async throws -> [EmailItem] {
        let out = try await AppleScript.run(MailScripts.unread(account: account, limit: limit), targetName: "Mail")
        return Self.emails(from: out)
    }

    public func search(_ query: String, limit: Int) async throws -> [EmailItem] {
        let out = try await AppleScript.run(MailScripts.search(query: query, limit: limit), targetName: "Mail")
        return Self.emails(from: out)
    }

    public func read(id: String) async throws -> EmailItem {
        let out = try await AppleScript.run(MailScripts.read(id: id), targetName: "Mail")
        if out == "NOTFOUND" { throw MacError(.notFound, "No message with id \(id).") }
        guard let item = Self.emails(from: out, bodyField: true).first else {
            throw MacError(.notFound, "No message with id \(id).")
        }
        return item
    }

    public func draft(_ draft: MailDraft) async throws {
        _ = try await AppleScript.run(MailScripts.compose(draft, send: false), targetName: "Mail")
    }

    public func send(_ draft: MailDraft) async throws {
        _ = try await AppleScript.run(MailScripts.compose(draft, send: true), targetName: "Mail")
    }

    public func markRead(id: String) async throws {
        let out = try await AppleScript.run(MailScripts.markRead(id: id), targetName: "Mail")
        if out == "NOTFOUND" { throw MacError(.notFound, "No message with id \(id).") }
    }

    public func archive(id: String) async throws {
        let out = try await AppleScript.run(MailScripts.archive(id: id), targetName: "Mail")
        if out == "NOTFOUND" { throw MacError(.notFound, "No message with id \(id).") }
        if out.hasPrefix("NOARCHIVE:") {
            let account = String(out.dropFirst("NOARCHIVE:".count))
            throw MacError(.notFound, "Account '\(account)' has no Archive mailbox.")
        }
    }

    static func emails(from output: String, bodyField: Bool = false) -> [EmailItem] {
        AppleScript.parseRecords(output).compactMap { fields in
            guard fields.count >= 6 else { return nil }
            return EmailItem(id: fields[0], subject: fields[1], from: fields[2],
                             date: dateFormatter.date(from: fields[3]) ?? Date(timeIntervalSince1970: 0),
                             isRead: fields[4] == "1",
                             account: fields[5],
                             body: bodyField && fields.count >= 7 ? fields[6] : nil)
        }
    }
}
```

- [ ] **Step 2: Implement the subcommands** — `Sources/MailModule/MailCommand.swift`

```swift
import ArgumentParser
import Core
import Foundation

struct ComposeOptions: ParsableArguments {
    @Option(help: "Recipient email address.") var to: String
    @Option(help: "CC email address.") var cc: String?
    @Option(help: "Subject line.") var subject: String = ""
    @Option(help: "Plain-text body.") var body: String = ""
}

public struct MailCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "mail",
        abstract: "Read, triage, and compose email via Mail.app.",
        subcommands: [Unread.self, Search.self, Read.self, Draft.self, Send.self,
                      MarkRead.self, Archive.self]
    )

    public init() {}

    struct Unread: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List unread inbox messages.",
            discussion: "Examples:\n  mac mail unread\n  mac mail unread --account Work --limit 10 --json"
        )

        @Option(help: "Only this account.") var account: String?
        @Option(help: "Maximum messages (default: 20).") var limit: Int = 20
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let items = try await MailActions(store: AppleScriptMailStore())
                    .unread(account: account, limit: limit)
                Output.emit(items, json: output.json)
            }
        }
    }

    struct Search: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Search inbox by subject or sender (not body).",
            discussion: "Example:\n  mac mail search \"invoice\" --limit 10 --json"
        )

        @Argument(help: "Text to match against subject and sender.") var query: String
        @Option(help: "Maximum messages (default: 20).") var limit: Int = 20
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let items = try await MailActions(store: AppleScriptMailStore())
                    .search(query: query, limit: limit)
                Output.emit(items, json: output.json)
            }
        }
    }

    struct Read: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show a message including its plain-text body, by exact id."
        )

        @Argument(help: "Message id from 'mac mail unread' or 'mac mail search'.") var id: String
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let item = try await MailActions(store: AppleScriptMailStore()).read(id: id)
                Output.emit(item, json: output.json)
            }
        }
    }

    struct Draft: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Compose a draft in Mail.app for you to review — does NOT send.",
            discussion: "Example:\n  mac mail draft --to a@b.com --subject \"Hi\" --body \"...\"\nAgents: prefer draft over send unless the user explicitly asked to send."
        )

        @OptionGroup var compose: ComposeOptions
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                try await MailActions(store: AppleScriptMailStore())
                    .compose(to: compose.to, cc: compose.cc, subject: compose.subject,
                             body: compose.body, send: false)
                if output.json {
                    print(#"{"draft":"opened"}"#)
                } else if !output.quiet {
                    print("draft opened in Mail")
                }
            }
        }
    }

    struct Send: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Compose and send an email immediately.",
            discussion: "Example:\n  mac mail send --to a@b.com --subject \"Hi\" --body \"...\""
        )

        @OptionGroup var compose: ComposeOptions
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                try await MailActions(store: AppleScriptMailStore())
                    .compose(to: compose.to, cc: compose.cc, subject: compose.subject,
                             body: compose.body, send: true)
                if output.json {
                    print(#"{"sent":"\#(compose.to)"}"#)
                } else if !output.quiet {
                    print("sent to \(compose.to)")
                }
            }
        }
    }

    struct MarkRead: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "mark-read",
            abstract: "Mark a message read by exact id."
        )

        @Argument(help: "Message id.") var id: String
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                try await MailActions(store: AppleScriptMailStore()).markRead(id: id)
                if output.json {
                    print(#"{"markedRead":"\#(id)"}"#)
                } else if !output.quiet {
                    print("marked read \(id)")
                }
            }
        }
    }

    struct Archive: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Move a message to its account's Archive mailbox, by exact id."
        )

        @Argument(help: "Message id.") var id: String
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                try await MailActions(store: AppleScriptMailStore()).archive(id: id)
                if output.json {
                    print(#"{"archived":"\#(id)"}"#)
                } else if !output.quiet {
                    print("archived \(id)")
                }
            }
        }
    }
}
```

- [ ] **Step 3: Register in the root command** — `Sources/MacCLI/Mac.swift`: add `import MailModule`, change subcommands to `[CalendarCommand.self, RemindersCommand.self, ContactsCommand.self, MailCommand.self, DoctorCommand.self]`.

- [ ] **Step 4: Write parsing tests** — `Tests/MailModuleTests/MailCommandParsingTests.swift`

```swift
import XCTest
@testable import MailModule

final class MailCommandParsingTests: XCTestCase {
    func testUnreadParses() throws {
        _ = try MailCommand.parseAsRoot(["unread", "--account", "Work", "--limit", "10", "--json"])
    }

    func testDraftRequiresTo() {
        XCTAssertThrowsError(try MailCommand.parseAsRoot(["draft", "--subject", "hi"]))
        XCTAssertNoThrow(try MailCommand.parseAsRoot(["draft", "--to", "a@b.com", "--subject", "hi"]))
    }

    func testMarkReadRequiresID() {
        XCTAssertThrowsError(try MailCommand.parseAsRoot(["mark-read"]))
        XCTAssertNoThrow(try MailCommand.parseAsRoot(["mark-read", "<m1@x>"]))
    }
}
```

- [ ] **Step 5: Build and test**

Run: `swift build && swift test --filter MailModuleTests`
Expected: `Build complete!`, PASS (17 tests in target: 8 actions + 6 scripts + 3 parsing).

Run: `swift run mac mail --help`
Expected: lists `unread, search, read, draft, send, mark-read, archive`.

Full `swift test`: 86 tests.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: add AppleScript mail store and mac mail subcommands"
```

---

### Task 7: MessagesModule — store protocol, actions, mock-backed tests

**Files:**
- Create: `Sources/MessagesModule/MessageStore.swift`
- Create: `Sources/MessagesModule/MessageActions.swift`
- Create: `Sources/MessagesModule/MessagesModule.swift` (placeholder comment: `// MessagesModule: chat.db reader + AppleScript sender and subcommands.`)
- Modify: `Package.swift` (add MessagesModule target + test target)
- Test: `Tests/MessagesModuleTests/MessageActionsTests.swift`

- [ ] **Step 1: Add targets to Package.swift**

After the MailModule target add:

```swift
        .target(name: "MessagesModule", dependencies: ["Core"]),
```

Add `"MessagesModule"` to MacCLI's dependencies. After MailModuleTests add:

```swift
        .testTarget(name: "MessagesModuleTests", dependencies: ["MessagesModule"]),
```

- [ ] **Step 2: Write the store protocol** — `Sources/MessagesModule/MessageStore.swift`

```swift
import Core
import Foundation

public protocol MessageStore {
    /// The most recent conversations, newest activity first.
    func conversations(limit: Int) async throws -> [ConversationInfo]
    /// The most recent `limit` messages with the handle, in any order —
    /// MessageActions sorts them oldest-to-newest for display.
    func history(handle: String, limit: Int) async throws -> [MessageItem]
    func send(handle: String, text: String) async throws
}
```

- [ ] **Step 3: Write the failing tests** — `Tests/MessagesModuleTests/MessageActionsTests.swift`

```swift
import XCTest
import Core
@testable import MessagesModule

final class MockMessageStore: MessageStore {
    var accessGranted = true
    var storedConversations: [ConversationInfo] = []
    var storedMessages: [MessageItem] = []
    var sent: [(handle: String, text: String)] = []

    private func gate() throws {
        if !accessGranted {
            throw MacError(.permissionDenied, "Cannot read Messages database. Run: mac doctor")
        }
    }

    func conversations(limit: Int) async throws -> [ConversationInfo] {
        try gate()
        return Array(storedConversations.prefix(limit))
    }

    func history(handle: String, limit: Int) async throws -> [MessageItem] {
        try gate()
        return Array(storedMessages.filter { $0.chat == handle }.prefix(limit))
    }

    func send(handle: String, text: String) async throws {
        try gate()
        sent.append((handle, text))
    }
}

final class MessageActionsTests: XCTestCase {
    var store = MockMessageStore()
    lazy var actions = MessageActions(store: store)
    let base = Date(timeIntervalSince1970: 1_787_824_800)

    func message(_ id: String, offset: TimeInterval) -> MessageItem {
        MessageItem(id: id, chat: "+15551234567", sender: "+15551234567",
                    text: id, date: base.addingTimeInterval(offset), isFromMe: false)
    }

    func testHistorySortsOldestToNewest() async throws {
        store.storedMessages = [message("newest", offset: 100), message("oldest", offset: 0),
                                message("middle", offset: 50)]
        let items = try await actions.history(handle: "+15551234567", limit: 30)
        XCTAssertEqual(items.map(\.id), ["oldest", "middle", "newest"])
    }

    func testEmptyHandleThrowsBadInput() async {
        do {
            _ = try await actions.history(handle: "  ", limit: 30)
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
        } catch { XCTFail("wrong error type") }
    }

    func testSendEmptyTextThrowsBadInput() async {
        do {
            try await actions.send(handle: "+15551234567", text: "  ")
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
        } catch { XCTFail("wrong error type") }
    }

    func testLimitOutOfRangeThrowsBadInput() async {
        do {
            _ = try await actions.conversations(limit: 0)
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
        } catch { XCTFail("wrong error type") }
    }

    func testSendPassesThrough() async throws {
        try await actions.send(handle: "+15551234567", text: "hello")
        XCTAssertEqual(store.sent.count, 1)
        XCTAssertEqual(store.sent[0].text, "hello")
    }

    func testPermissionDeniedPropagates() async {
        store.accessGranted = false
        do {
            _ = try await actions.conversations(limit: 5)
            XCTFail("expected permissionDenied")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .permissionDenied)
        } catch { XCTFail("wrong error type") }
    }
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `swift test --filter MessageActionsTests`
Expected: compile FAILURE — `cannot find 'MessageActions' in scope`

- [ ] **Step 5: Implement** — `Sources/MessagesModule/MessageActions.swift`

```swift
import Core
import Foundation

public struct MessageActions {
    let store: MessageStore

    public init(store: MessageStore) {
        self.store = store
    }

    public func conversations(limit: Int) async throws -> [ConversationInfo] {
        try validate(limit: limit)
        return try await store.conversations(limit: limit)
    }

    public func history(handle: String, limit: Int) async throws -> [MessageItem] {
        let trimmed = try validated(handle: handle)
        try validate(limit: limit)
        return try await store.history(handle: trimmed, limit: limit)
            .sorted { $0.date < $1.date }
    }

    public func send(handle: String, text: String) async throws {
        let trimmed = try validated(handle: handle)
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw MacError(.badInput, "Message text cannot be empty.")
        }
        try await store.send(handle: trimmed, text: text)
    }

    func validated(handle: String) throws -> String {
        let trimmed = handle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw MacError(.badInput, "Handle cannot be empty. Use a phone number or iMessage email; find one with: mac contacts find <name>")
        }
        return trimmed
    }

    func validate(limit: Int) throws {
        guard (1...500).contains(limit) else {
            throw MacError(.badInput, "--limit must be between 1 and 500.")
        }
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter MessageActionsTests`
Expected: PASS (6 tests). Full suite: 92 tests.

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "feat: add MessageStore protocol and mock-tested MessageActions"
```

---

### Task 8: MessagesModule — ChatDBReader with fixture-database tests

**Files:**
- Create: `Sources/MessagesModule/ChatDBReader.swift`
- Test: `Tests/MessagesModuleTests/ChatDBReaderTests.swift`

The reader opens chat.db read-only and never writes. Two correctness-critical details, both fixture-tested: `attributedBody` typedstream text extraction (many modern rows have NULL `text`), and Apple-epoch date conversion (nanoseconds since 2001-01-01; legacy seconds scale handled).

- [ ] **Step 1: Write the failing tests** — `Tests/MessagesModuleTests/ChatDBReaderTests.swift`

```swift
import XCTest
import SQLite3
import Core
@testable import MessagesModule

final class ChatDBReaderTests: XCTestCase {
    var dbPath: String = ""

    /// Builds a minimal fixture chat.db with the real table/column names.
    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-cli-chatdb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbPath = dir.appendingPathComponent("chat.db").path

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        let schema = """
        CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, chat_identifier TEXT, display_name TEXT);
        CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
        CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT,
                              attributedBody BLOB, date INTEGER, is_from_me INTEGER, handle_id INTEGER);
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
        CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
        INSERT INTO chat VALUES (1, '+15551234567', '');
        INSERT INTO handle VALUES (1, '+15551234567');
        INSERT INTO chat_handle_join VALUES (1, 1);
        -- plain-text message: 2026-08-27T10:00:00Z in Apple ns epoch
        INSERT INTO message VALUES (1, 'g-text', 'hello world', NULL, 809517600000000000, 0, 1);
        INSERT INTO chat_message_join VALUES (1, 1);
        -- from-me message 60s later, text only
        INSERT INTO message VALUES (2, 'g-me', 'my reply', NULL, 809517660000000000, 1, NULL);
        INSERT INTO chat_message_join VALUES (1, 2);
        """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)

        // attributedBody-only message 120s later: typedstream-style blob for "blob text"
        var blob: [UInt8] = Array("junkprefix".utf8)
        blob += Array("NSString".utf8)
        blob += [0x01, 0x94, 0x84, 0x01, 0x2B]
        let payload = Array("blob text".utf8)
        blob += [UInt8(payload.count)]
        blob += payload
        var stmt: OpaquePointer?
        let insert = "INSERT INTO message VALUES (3, 'g-blob', NULL, ?, 809517720000000000, 0, 1);"
        XCTAssertEqual(sqlite3_prepare_v2(db, insert, -1, &stmt, nil), SQLITE_OK)
        blob.withUnsafeBytes { raw in
            _ = sqlite3_bind_blob(stmt, 1, raw.baseAddress, Int32(raw.count),
                                  unsafeBitCast(-1, to: sqlite3_destructor_type.self)) // SQLITE_TRANSIENT
        }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
        sqlite3_finalize(stmt)
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO chat_message_join VALUES (1, 3);", nil, nil, nil), SQLITE_OK)
    }

    func testHistoryReadsTextBlobAndDates() throws {
        let reader = ChatDBReader(path: dbPath)
        let items = try reader.history(handle: "+15551234567", limit: 10)
        XCTAssertEqual(items.count, 3)
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        XCTAssertEqual(byID["g-text"]?.text, "hello world")
        XCTAssertEqual(byID["g-text"]?.sender, "+15551234567")
        XCTAssertEqual(byID["g-text"]?.isFromMe, false)
        XCTAssertEqual(byID["g-text"]?.date, Date(timeIntervalSince1970: 1_787_824_800)) // 2026-08-27T10:00:00Z
        XCTAssertEqual(byID["g-me"]?.sender, "me")
        XCTAssertEqual(byID["g-me"]?.isFromMe, true)
        XCTAssertEqual(byID["g-blob"]?.text, "blob text")
    }

    func testConversations() throws {
        let reader = ChatDBReader(path: dbPath)
        let convos = try reader.conversations(limit: 10)
        XCTAssertEqual(convos.count, 1)
        XCTAssertEqual(convos[0].id, "+15551234567")
        XCTAssertEqual(convos[0].name, "+15551234567") // empty display_name falls back to identifier
        XCTAssertEqual(convos[0].isGroup, false)
        XCTAssertEqual(convos[0].lastActivity, Date(timeIntervalSince1970: 1_787_824_920))
    }

    func testUnreadablePathThrowsPermissionDenied() {
        let reader = ChatDBReader(path: "/nonexistent/dir/chat.db")
        do {
            _ = try reader.conversations(limit: 5)
            XCTFail("expected permissionDenied")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .permissionDenied)
            XCTAssertTrue(error.message.contains("Full Disk Access"))
        } catch { XCTFail("wrong error type") }
    }

    func testTypedstreamExtraction() {
        var blob: [UInt8] = Array("NSString".utf8) + [0x01, 0x94, 0x84, 0x01, 0x2B, 0x02] + Array("hi".utf8)
        XCTAssertEqual(ChatDBReader.extractText(fromAttributedBody: Data(blob)), "hi")

        // long form: 0x81 marker + little-endian u16 length
        let long = String(repeating: "a", count: 300)
        blob = Array("NSString".utf8) + [0x01, 0x94, 0x84, 0x01, 0x2B, 0x81, 0x2C, 0x01] + Array(long.utf8)
        XCTAssertEqual(ChatDBReader.extractText(fromAttributedBody: Data(blob)), long)

        XCTAssertNil(ChatDBReader.extractText(fromAttributedBody: Data("garbage".utf8)))
    }

    func testAppleEpochConversion() {
        XCTAssertEqual(ChatDBReader.date(fromAppleEpoch: 809_517_600_000_000_000),
                       Date(timeIntervalSince1970: 1_787_824_800)) // ns scale
        XCTAssertEqual(ChatDBReader.date(fromAppleEpoch: 809_517_600),
                       Date(timeIntervalSince1970: 1_787_824_800)) // legacy seconds scale
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ChatDBReaderTests`
Expected: compile FAILURE — `cannot find 'ChatDBReader' in scope`

- [ ] **Step 3: Implement** — `Sources/MessagesModule/ChatDBReader.swift`

```swift
import Core
import Foundation
import SQLite3

/// Read-only reader over Messages' chat.db. Never writes; never blocks Messages.app.
public final class ChatDBReader {
    let path: String

    public init(path: String = NSHomeDirectory() + "/Library/Messages/chat.db") {
        self.path = path
    }

    static let deniedError = MacError(
        .permissionDenied,
        "Cannot read the Messages database. Grant Full Disk Access to your terminal app in System Settings > Privacy & Security > Full Disk Access, or run: mac doctor"
    )

    public func conversations(limit: Int) throws -> [ConversationInfo] {
        try withDB { db in
            let sql = """
            SELECT c.chat_identifier,
                   COALESCE(NULLIF(c.display_name, ''), c.chat_identifier) AS name,
                   MAX(m.date) AS last_date,
                   (SELECT COUNT(*) FROM chat_handle_join chj WHERE chj.chat_id = c.ROWID) AS participants
            FROM chat c
            JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
            JOIN message m ON m.ROWID = cmj.message_id
            GROUP BY c.ROWID
            ORDER BY last_date DESC
            LIMIT ?;
            """
            let stmt = try prepare(db, sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(limit))
            var out: [ConversationInfo] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(ConversationInfo(
                    id: text(stmt, 0),
                    name: text(stmt, 1),
                    lastActivity: Self.date(fromAppleEpoch: sqlite3_column_int64(stmt, 2)),
                    isGroup: sqlite3_column_int(stmt, 3) > 1))
            }
            return out
        }
    }

    public func history(handle: String, limit: Int) throws -> [MessageItem] {
        try withDB { db in
            let sql = """
            SELECT m.guid,
                   COALESCE(NULLIF(c.display_name, ''), c.chat_identifier) AS chat,
                   h.id AS sender, m.text, m.attributedBody, m.date, m.is_from_me
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat c ON c.ROWID = cmj.chat_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE c.chat_identifier = ?
            ORDER BY m.date DESC
            LIMIT ?;
            """
            let stmt = try prepare(db, sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, handle, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_int(stmt, 2, Int32(limit))
            var out: [MessageItem] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let isFromMe = sqlite3_column_int(stmt, 6) == 1
                let body: String
                if sqlite3_column_type(stmt, 3) != SQLITE_NULL, !text(stmt, 3).isEmpty {
                    body = text(stmt, 3)
                } else if sqlite3_column_type(stmt, 4) != SQLITE_NULL,
                          let decoded = Self.extractText(fromAttributedBody: blob(stmt, 4)) {
                    body = decoded
                } else {
                    body = "⟨unsupported content⟩"
                }
                out.append(MessageItem(
                    id: text(stmt, 0),
                    chat: text(stmt, 1),
                    sender: isFromMe ? "me" : (sqlite3_column_type(stmt, 2) != SQLITE_NULL ? text(stmt, 2) : text(stmt, 1)),
                    text: body,
                    date: Self.date(fromAppleEpoch: sqlite3_column_int64(stmt, 5)),
                    isFromMe: isFromMe))
            }
            return out
        }
    }

    // MARK: - Internals

    func withDB<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw Self.deniedError
        }
        defer { sqlite3_close(db) }
        return try body(db)
    }

    func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw NSError(domain: "ChatDB", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "chat.db query failed: \(String(cString: sqlite3_errmsg(db)))"])
        }
        return stmt
    }

    func text(_ stmt: OpaquePointer, _ col: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: c)
    }

    func blob(_ stmt: OpaquePointer, _ col: Int32) -> Data {
        guard let base = sqlite3_column_blob(stmt, col) else { return Data() }
        return Data(bytes: base, count: Int(sqlite3_column_bytes(stmt, col)))
    }

    /// chat.db stores dates as nanoseconds since 2001-01-01 (seconds on very old
    /// databases). Values above ~1e12 can only be the nanosecond scale.
    static func date(fromAppleEpoch raw: Int64) -> Date {
        let seconds = raw > 1_000_000_000_000 ? Double(raw) / 1_000_000_000 : Double(raw)
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// Heuristic typedstream text extraction: the plain string follows an
    /// "NSString" marker + the byte sequence 01 94 84 01 2B, length-prefixed
    /// (single byte, or 0x81 + little-endian u16 for long strings).
    static func extractText(fromAttributedBody data: Data) -> String? {
        let bytes = [UInt8](data)
        let needle = Array("NSString".utf8)
        guard bytes.count > needle.count,
              let start = (0...(bytes.count - needle.count)).first(where: { Array(bytes[$0..<$0 + needle.count]) == needle })
        else { return nil }
        var i = start + needle.count
        let expected: [UInt8] = [0x01, 0x94, 0x84, 0x01, 0x2B]
        guard i + expected.count < bytes.count,
              Array(bytes[i..<i + expected.count]) == expected else { return nil }
        i += expected.count
        var length = Int(bytes[i])
        i += 1
        if length == 0x81 {
            guard i + 1 < bytes.count else { return nil }
            length = Int(bytes[i]) | (Int(bytes[i + 1]) << 8)
            i += 2
        }
        guard i + length <= bytes.count else { return nil }
        return String(bytes: bytes[i..<i + length], encoding: .utf8)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ChatDBReaderTests`
Expected: PASS (5 tests). Full suite: 97 tests.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: add read-only chat.db reader with typedstream and epoch handling"
```

---

### Task 9: MessagesModule — sender script, live store, subcommands, root wiring

**Files:**
- Create: `Sources/MessagesModule/MessagesScripts.swift`
- Create: `Sources/MessagesModule/LiveMessageStore.swift`
- Create: `Sources/MessagesModule/MessagesCommand.swift`
- Modify: `Sources/MacCLI/Mac.swift`
- Test: `Tests/MessagesModuleTests/MessagesScriptsTests.swift`, `Tests/MessagesModuleTests/MessagesCommandParsingTests.swift`

- [ ] **Step 1: Write the failing script-builder test** — `Tests/MessagesModuleTests/MessagesScriptsTests.swift`

```swift
import XCTest
@testable import MessagesModule

final class MessagesScriptsTests: XCTestCase {
    func testSendScriptEscapesTextAndHandle() {
        let script = MessagesScripts.send(handle: "+15551234567", text: #"say "hi" \now"#)
        XCTAssertTrue(script.contains(#"say \"hi\" \\now"#))
        XCTAssertTrue(script.contains(#"participant "+15551234567""#))
        XCTAssertTrue(script.contains("service type = iMessage"))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter MessagesScriptsTests`
Expected: compile FAILURE — `cannot find 'MessagesScripts' in scope`

- [ ] **Step 3: Implement the sender script + live store**

`Sources/MessagesModule/MessagesScripts.swift`:

```swift
import Core
import Foundation

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
```

`Sources/MessagesModule/LiveMessageStore.swift`:

```swift
import Core
import Foundation

/// Hybrid store: reads from chat.db, sends via Messages AppleScript.
public final class LiveMessageStore: MessageStore {
    let reader: ChatDBReader

    public init(reader: ChatDBReader = ChatDBReader()) {
        self.reader = reader
    }

    public func conversations(limit: Int) async throws -> [ConversationInfo] {
        try reader.conversations(limit: limit)
    }

    public func history(handle: String, limit: Int) async throws -> [MessageItem] {
        try reader.history(handle: handle, limit: limit)
    }

    public func send(handle: String, text: String) async throws {
        _ = try await AppleScript.run(MessagesScripts.send(handle: handle, text: text),
                                      targetName: "Messages")
    }
}
```

- [ ] **Step 4: Implement the subcommands** — `Sources/MessagesModule/MessagesCommand.swift`

```swift
import ArgumentParser
import Core
import Foundation

public struct MessagesCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "messages",
        abstract: "Read iMessage history and send messages.",
        subcommands: [Chats.self, History.self, Send.self]
    )

    public init() {}

    struct Chats: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List recent conversations.",
            discussion: "Example:\n  mac messages chats --limit 10 --json"
        )

        @Option(help: "Maximum conversations (default: 20).") var limit: Int = 20
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let items = try await MessageActions(store: LiveMessageStore()).conversations(limit: limit)
                Output.emit(items, json: output.json)
            }
        }
    }

    struct History: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show recent messages with a handle, oldest first.",
            discussion: "Handles are phone numbers or iMessage emails — find them with:\n  mac contacts find <name>\nExample:\n  mac messages history +15551234567 --limit 30"
        )

        @Argument(help: "Phone number or iMessage email.") var handle: String
        @Option(help: "Maximum messages (default: 30).") var limit: Int = 30
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let items = try await MessageActions(store: LiveMessageStore())
                    .history(handle: handle, limit: limit)
                Output.emit(items, json: output.json)
            }
        }
    }

    struct Send: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Send an iMessage to an exact handle.",
            discussion: "Example:\n  mac messages send +15551234567 \"Running 10 min late\""
        )

        @Argument(help: "Phone number or iMessage email (exact — no name lookup).") var handle: String
        @Argument(help: "Message text.") var text: String
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                try await MessageActions(store: LiveMessageStore()).send(handle: handle, text: text)
                if output.json {
                    print(#"{"sent":"\#(handle)"}"#)
                } else if !output.quiet {
                    print("sent to \(handle)")
                }
            }
        }
    }
}
```

- [ ] **Step 5: Register in the root command** — `Sources/MacCLI/Mac.swift`: add `import MessagesModule`, change subcommands to `[CalendarCommand.self, RemindersCommand.self, ContactsCommand.self, MailCommand.self, MessagesCommand.self, DoctorCommand.self]`.

- [ ] **Step 6: Write parsing tests** — `Tests/MessagesModuleTests/MessagesCommandParsingTests.swift`

```swift
import XCTest
@testable import MessagesModule

final class MessagesCommandParsingTests: XCTestCase {
    func testChatsParses() throws {
        _ = try MessagesCommand.parseAsRoot(["chats", "--limit", "10", "--json"])
    }

    func testHistoryRequiresHandle() {
        XCTAssertThrowsError(try MessagesCommand.parseAsRoot(["history"]))
        XCTAssertNoThrow(try MessagesCommand.parseAsRoot(["history", "+15551234567"]))
    }

    func testSendRequiresHandleAndText() {
        XCTAssertThrowsError(try MessagesCommand.parseAsRoot(["send", "+15551234567"]))
        XCTAssertNoThrow(try MessagesCommand.parseAsRoot(["send", "+15551234567", "hello"]))
    }
}
```

- [ ] **Step 7: Build and test**

Run: `swift build && swift test --filter MessagesModuleTests`
Expected: `Build complete!`, PASS (15 tests in target: 6 actions + 5 reader + 1 script + 3 parsing).

Run: `swift run mac messages --help` — lists `chats, history, send`. `swift run mac --help` — six subcommands.

Full `swift test`: 101 tests.

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "feat: add live message store and mac messages subcommands"
```

---

### Task 10: README, smoke-test extension, plan wrap-up

**Files:**
- Modify: `README.md`
- Modify: `scripts/smoke.sh`

- [ ] **Step 1: Update the README**

In the intro line, change "Calendar, Reminders, and Contacts today" to "Calendar, Reminders, Contacts, Mail, and Messages". In **Usage**, append:

```sh
mac mail unread --limit 10
mac mail search "invoice"
mac mail draft --to a@b.com --subject "Hi" --body "..."
mac messages history +15551234567
mac messages send +15551234567 "Running 10 min late"
```

In **First run**, append after the doctor snippet:

```markdown
Mail and Messages additionally need Automation consent (prompted on first use) and, for reading Messages history, Full Disk Access for your terminal app — `mac doctor` reports all of it with fix steps.
```

In **For agents**, append:

```markdown
- Prefer `mac mail draft` over `mac mail send` unless the user explicitly asked to send.
- `mac messages send` takes exact handles only — resolve names with `mac contacts find` first.
```

In **Known limitations (v1)**, rename the heading to **Known limitations** and append:

```markdown
- Mail search matches subject/sender only (no body search); reads are scoped to account inboxes.
- Mail composition is plain-text; no attachments.
- Messages: group chats are read-only; SMS-relay sends are best-effort; sends require an exact handle.
```

Remove the "Mail, Messages, and Notes modules" Roadmap line and replace with:

```markdown
Notes module (AppleScript-backed behind the same command surface).
```

- [ ] **Step 2: Extend the smoke test** — append to `scripts/smoke.sh` before the final `echo "PASS"`:

```bash
echo "== mail =="
"$MAC" mail unread --limit 3 >/dev/null
"$MAC" mail search "mac-cli-smoke-should-match-nothing" --json | grep -q '\[\]'
"$MAC" mail draft --to "smoke@example.com" --subject "mac-cli smoke draft — safe to close" --body "Created by scripts/smoke.sh; close this window." --quiet
echo "   (a draft window opened in Mail — close it whenever)"

echo "== messages =="
if [ -n "${SMOKE_HANDLE:-}" ]; then
  "$MAC" messages chats --limit 3 >/dev/null
  "$MAC" messages send "$SMOKE_HANDLE" "mac-cli smoke test" --quiet
  sleep 2
  "$MAC" messages history "$SMOKE_HANDLE" --limit 5 | grep -q "mac-cli smoke test"
else
  "$MAC" messages chats --limit 3 >/dev/null
  echo "   (set SMOKE_HANDLE=+1555… to also test send+history round-trip)"
fi
```

Note: the mail draft is left open with a self-describing subject for the user to close (deleting drafts via AppleScript is unreliable); the messages round-trip self-sends to the user's own handle when `SMOKE_HANDLE` is set.

- [ ] **Step 3: Verify**

Run: `make test` — 101 tests, 0 failures. `bash -n scripts/smoke.sh` — no output. Do NOT run the smoke script (user-run, from Terminal).

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "docs: document Mail/Messages usage, permissions, and smoke coverage"
```

---

## Done criteria

- `swift test` passes (~101 tests) with zero TCC/Automation/FDA permissions — everything mocked or fixture-backed.
- `mac --help` shows six subcommand trees; `mac doctor` shows six capability rows and never prompts.
- Escaping is enforced at every AppleScript interpolation site (all through `AppleScript.escape`).
- User-run `make smoke` from Terminal passes end-to-end, including the Messages round-trip with `SMOKE_HANDLE` set.
- README documents the new commands, permissions, and limitations (including draft-over-send agent guidance).



