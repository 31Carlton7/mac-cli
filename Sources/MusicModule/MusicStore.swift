import Core
import Foundation

public protocol MusicStore {
    func playerState() async throws -> PlayerState
    func resume() async throws
    func pause() async throws
    func next() async throws
    func previous() async throws
    func setVolume(_ volume: Int) async throws
    func playPlaylist(id: String) async throws -> Bool
    func playTrack(id: String) async throws -> Bool
    func search(_ query: String, limit: Int) async throws -> [TrackItem]
    func playlists() async throws -> [PlaylistInfo]
    func createPlaylist(name: String) async throws -> PlaylistInfo
    func addTrack(id: String, toPlaylist playlistID: String) async throws -> Bool
    func removeTrack(id: String, fromPlaylist playlistID: String) async throws -> Bool
    func deletePlaylist(id: String) async throws -> Bool
    func rate(trackID: String, rating0to100: Int) async throws -> Bool
}
