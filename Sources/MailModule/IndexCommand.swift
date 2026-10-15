import ArgumentParser
import Core
import Foundation

extension MailCommand {
    struct Index: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Build and check the local index that body: searches.",
            discussion: """
                Mail keeps no searchable copy of message bodies that other apps \
                can read, so mac decodes each message file once and keeps a \
                full-text index of the words in it at \
                ~/Library/Caches/mac-cli/mail-bodies.sqlite (owner-only). The \
                index holds private mail content; delete it with \
                mac mail index clear.
                """,
            subcommands: [Build.self, Status.self, Clear.self]
        )

        struct Build: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Index message bodies so body: can search them.",
                discussion: """
                    The first build decodes every message of every enabled \
                    account; later builds decode only messages Mail stored \
                    since, plus those whose file Mail had not downloaded yet, \
                    and drop messages Mail no longer has. Progress goes to \
                    stderr. Ctrl-C stops after the current batch and keeps \
                    what is done; the next build resumes there.

                    Never writes to Mail's files.

                    Examples:
                      mac mail index build
                      mac mail index build --account Work --limit 5000 --json
                    """
            )

            @Option(help: "Only this account.") var account: String?
            @Option(help: "Index at most this many messages, then stop.") var limit: Int?
            @OptionGroup var accountCache: AccountCacheOptions
            @OptionGroup var output: OutputOptions

            func run() async {
                await withErrorHandling(json: output.json) {
                    let stop = StopRequest()
                    let signals = MailCommand.onInterrupt { stop.request() }
                    defer { signals.forEach { $0.cancel() } }
                    let meter = ProgressLine(quiet: output.quiet)
                    let build = try await MailActions(store: AppleScriptMailStore(), index: accountCache.index)
                        .buildBodyIndex(account: account, limit: limit,
                                        progress: meter.show, shouldStop: { stop.isRequested })
                    meter.finish()
                    Output.emit(build, json: output.json)
                }
            }
        }

        struct Status: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Show how much of your mail the body index covers.",
                discussion: """
                    Counts only, never message content: messages indexed, \
                    those whose file was missing, malformed or unreadable, \
                    each account's watermark (the highest Mail ROWID its \
                    build reached), Mail's newest ROWID, how many messages \
                    body: cannot see yet, the file size and the last build.

                    Example:
                      mac mail index status --json
                    """
            )

            @Option(help: "Only this account.") var account: String?
            @OptionGroup var accountCache: AccountCacheOptions
            @OptionGroup var output: OutputOptions

            func run() async {
                await withErrorHandling(json: output.json) {
                    let status = try await MailActions(store: AppleScriptMailStore(), index: accountCache.index)
                        .bodyIndexStatus(account: account)
                    Output.emit(status, json: output.json)
                }
            }
        }

        struct Clear: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Delete the body index file.",
                discussion: """
                    Deletes ~/Library/Caches/mac-cli/mail-bodies.sqlite. body: \
                    stops working until the next mac mail index build.
                    """
            )

            @OptionGroup var output: OutputOptions

            func run() async {
                await withErrorHandling(json: output.json) {
                    let index = MailBodyIndex()
                    let existed = try index.clear()
                    if output.json {
                        print(#"{"cleared":\#(existed)}"#)
                    } else if !output.quiet {
                        print(existed ? "deleted \(index.path)" : "no body index at \(index.path)")
                    }
                }
            }
        }
    }
}

/// Set from a signal handler, read between batches.
final class StopRequest {
    private let lock = NSLock()
    private var requested = false

    func request() {
        lock.lock()
        requested = true
        lock.unlock()
    }

    var isRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }
}

/// Build progress on stderr: one line rewritten in place on a terminal,
/// a line every few seconds otherwise.
final class ProgressLine {
    private let quiet: Bool
    private let terminal = isatty(STDERR_FILENO) != 0
    private let started = Date()
    private var shown = Date.distantPast
    private var drewLine = false

    init(quiet: Bool) {
        self.quiet = quiet
    }

    func show(_ done: Int, _ total: Int) {
        guard !quiet else { return }
        let now = Date()
        guard done == total || now.timeIntervalSince(shown) >= (terminal ? 0.2 : 5) else { return }
        shown = now
        let elapsed = now.timeIntervalSince(started)
        let rate = elapsed > 0 ? Int(Double(done) / elapsed) : 0
        let line = "indexing \(done)/\(total) messages (\(rate)/s)"
        FileHandle.standardError.write(Data((terminal ? "\r" + line : line + "\n").utf8))
        drewLine = terminal
    }

    func finish() {
        if drewLine { FileHandle.standardError.write(Data("\n".utf8)) }
    }
}
