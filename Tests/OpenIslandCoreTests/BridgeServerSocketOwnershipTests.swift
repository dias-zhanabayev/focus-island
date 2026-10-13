import Foundation
import Testing
@testable import OpenIslandCore

struct BridgeServerSocketOwnershipTests {
    @Test
    func secondInstanceDoesNotStealLiveSocket() throws {
        let socketURL = BridgeSocketLocation.uniqueTestURL()
        let first = BridgeServer(socketURL: socketURL)
        try first.start()
        defer { first.stop() }

        let second = BridgeServer(socketURL: socketURL)
        #expect(throws: BridgeTransportError.self) { try second.start() }
        #expect(BridgeServer.hasLiveListener(at: socketURL))
    }

    @Test
    func staleSocketFileIsReplaced() throws {
        let socketURL = BridgeSocketLocation.uniqueTestURL()
        let stale = BridgeServer(socketURL: socketURL)
        try stale.start()
        stale.stop()
        if !FileManager.default.fileExists(atPath: socketURL.path) {
            FileManager.default.createFile(atPath: socketURL.path, contents: nil)
        }
        #expect(!BridgeServer.hasLiveListener(at: socketURL))

        let fresh = BridgeServer(socketURL: socketURL)
        try fresh.start()
        defer { fresh.stop() }
        #expect(BridgeServer.hasLiveListener(at: socketURL))
    }
}
