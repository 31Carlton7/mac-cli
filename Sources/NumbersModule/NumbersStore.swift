import Core
import Foundation

public protocol NumbersStore {
    func docs() async throws -> [IWorkDocInfo]
    func newDoc(savePath: String?) async throws -> IWorkDocInfo
    func getCell(doc: String, sheet: Int, table: Int, cell: String) async throws -> String
    func setCell(doc: String, sheet: Int, table: Int, cell: String, value: String) async throws
    func export(doc: String, format: String, path: String) async throws   // "pdf"|"xlsx"|"csv"
}
