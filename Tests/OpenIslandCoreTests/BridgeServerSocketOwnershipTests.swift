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
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try withUnixSocketAddress(path: socketURL.path) { address, length in
            _ = bind(fd, address, length)
        }
        close(fd)
        #expect(FileManager.default.fileExists(atPath: socketURL.path))
        #expect(!BridgeServer.hasLiveListener(at: socketURL))

        let fresh = BridgeServer(socketURL: socketURL)
        try fresh.start()
        defer { fresh.stop() }
        #expect(BridgeServer.hasLiveListener(at: socketURL))
    }
}
