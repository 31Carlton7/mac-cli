import Foundation

public struct MacError: Error, Equatable {
    public enum Code: String, Codable {
        case notFound, badInput, permissionDenied
    }

    public let code: Code
    public let message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }

    public var exitCode: Int32 { code == .permissionDenied ? 2 : 1 }

    public var jsonString: String {
        let payload: [String: [String: String]] = ["error": ["code": code.rawValue, "message": message]]
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)! + "\n"
    }
}

/// Runs a command body, printing MacErrors to stderr and exiting with the mapped code.
/// Commands wrap their entire run() in this so agents get stable exit codes.
public func withErrorHandling(json: Bool, _ body: () async throws -> Void) async {
    do {
        try await body()
    } catch let error as MacError {
        let text = json ? error.jsonString : "\(error.message)\n"
        FileHandle.standardError.write(Data(text.utf8))
        exit(error.exitCode)
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}
