import Core
import Foundation

public protocol TVStore {
    func playerState() async throws -> PlayerState   // track fields reused; artist=show or "", album=""
    func pause() async throws
    func resume() async throws
    func list(limit: Int) async throws -> [TVItem]
    func play(id: String) async throws -> Bool
}
