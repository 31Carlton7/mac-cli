import XCTest

/// Names that try to break out of a string literal: quotes, backslashes,
/// line breaks, AppleScript keywords and non-ASCII text.
let hostileNames = [
    #"Wo"rk"#,
    #"back\slash\"#,
    "two\nlines\r",
    #"" & (do shell script "true") & ""#,
    "end tell",
    "Ünïcødé 📬 «class mssg»",
]

/// Compiles `script` with osacompile, which parses it against Mail's
/// dictionary without running anything, so a script AppleScript would refuse
/// fails here rather than on the user's first run.
func assertCompiles(_ script: String, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
    process.arguments = ["-o", "/dev/null"]
    let input = Pipe()
    let errors = Pipe()
    process.standardInput = input
    process.standardError = errors
    do {
        try process.run()
    } catch {
        XCTFail("\(name): cannot run osacompile: \(error)", file: file, line: line)
        return
    }
    input.fileHandleForWriting.write(Data(script.utf8))
    try? input.fileHandleForWriting.close()
    let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0, "\(name) does not compile: \(message)", file: file, line: line)
}
