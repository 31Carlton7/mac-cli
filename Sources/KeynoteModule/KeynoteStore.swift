import Core
import Foundation

public protocol KeynoteStore {
    func docs() async throws -> [IWorkDocInfo]
    func themes() async throws -> [String]
    func newDoc(theme: String?, savePath: String?) async throws -> IWorkDocInfo
    func addSlide(doc: String, title: String, body: String?) async throws
    func slides(doc: String) async throws -> [SlideInfo]
    func export(doc: String, format: String, path: String) async throws   // format: "pdf"|"pptx"
}
