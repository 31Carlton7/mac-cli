import Core
import Foundation

public protocol PagesStore {
    func docs() async throws -> [IWorkDocInfo]
    func newDoc(savePath: String?) async throws -> IWorkDocInfo
    func getBody(doc: String) async throws -> String
    func setBody(doc: String, text: String) async throws
    func appendBody(doc: String, text: String) async throws
    func export(doc: String, format: String, path: String) async throws   // "pdf"|"docx"
}
