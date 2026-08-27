import Core
import Foundation

public protocol FinderStore {
    func selection() async throws -> [FinderItem]
    func reveal(path: String) async throws
    func open(path: String) async throws
    func trash(path: String) async throws
    func disks() async throws -> [DiskInfo]
    func eject(name: String) async throws -> Bool   // false = unknown disk at eject time
}
