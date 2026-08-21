import XCTest
@testable import GModGameSession

final class GModPlayableSessionSinglePlayerGLuaBridgeTests: XCTestCase {
    func testPlayableSessionInstallsServerOnlySinglePlayerEntityABI() throws {
        let configuration = GModPlayableSessionConfiguration(
            map: .construct,
            playerEntityIndex: 7,
            playerUserID: 70
        )
        let session = try GModPlayableSession(configuration: configuration)
        defer { _ = try? session.close() }

        try session.serverRuntime.execute(
            """
            local ply = Player(70)
            assert(ply == Entity(7))
            assert(ply:UniqueID() == 1)
            assert(ply:IsMarkedForDeletion() == false)
            """,
            sourceName: "=(playable single-player SERVER ABI)"
        )
        try session.clientRuntime.execute(
            """
            local ply = LocalPlayer()
            assert(ply.UniqueID == nil)
            assert(ply.IsMarkedForDeletion == nil)
            """,
            sourceName: "=(playable CLIENT has no SERVER single-player ABI)"
        )
    }
}
