import Foundation
import Testing
@testable import OpenIslandCore

struct BridgeTransportPathTests {
    @Test
    func stableDirectoryIsFocusIsland() {
        #expect(BridgeSocketLocation.stableDirectoryURL.lastPathComponent == "FocusIsland")
    }
}
