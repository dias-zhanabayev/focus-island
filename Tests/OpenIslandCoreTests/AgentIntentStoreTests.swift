import Foundation
import Testing
@testable import OpenIslandCore

struct AgentIntentStoreTests {
    @Test
    func intentDefaultsToUntouchedForNewStore() {
        let (store, _) = makeStore()

        for agent in AgentIdentifier.allCases {
            #expect(store.intent(for: agent) == .untouched)
        }
    }

    @Test
    func setIntentPersistsAndReadsBack() {
        let (store, defaults) = makeStore()
        store.setIntent(.installed, for: .claudeCode)
        store.setIntent(.uninstalled, for: .claudeUsageBridge)

        #expect(store.intent(for: .claudeCode) == .installed)
        #expect(store.intent(for: .claudeUsageBridge) == .uninstalled)

        let reopened = AgentIntentStore(defaults: defaults)
        #expect(reopened.intent(for: .claudeCode) == .installed)
        #expect(reopened.intent(for: .claudeUsageBridge) == .uninstalled)
    }

    @Test
    func installedAgentsReportsOnlyInstalled() {
        let (store, _) = makeStore()
        store.setIntent(.installed, for: .claudeCode)
        store.setIntent(.uninstalled, for: .claudeUsageBridge)

        let installed = Set(store.installedAgents())
        #expect(installed == Set([.claudeCode]))
    }

    @Test
    func migrationStampsInstalledForAgentsAlreadyOnDisk() {
        let (store, defaults) = makeStore()
        let present: Set<AgentIdentifier> = [.claudeCode]

        let ranWithInstalled = store.migrateFromLegacyStateIfNeeded { present.contains($0) }

        #expect(ranWithInstalled == true)
        #expect(store.intent(for: .claudeCode) == .installed)
        #expect(store.intent(for: .claudeUsageBridge) == .untouched)
        #expect(store.firstLaunchCompleted == true)
        #expect(defaults.integer(forKey: "agentIntentMigrationVersion") == 1)
    }

    @Test
    func migrationLeavesFirstLaunchUnsetWhenNoHooksPresent() {
        let (store, _) = makeStore()

        let ranWithInstalled = store.migrateFromLegacyStateIfNeeded { _ in false }

        #expect(ranWithInstalled == false)
        for agent in AgentIdentifier.allCases {
            #expect(store.intent(for: agent) == .untouched)
        }
        #expect(store.firstLaunchCompleted == false)
    }

    @Test
    func migrationIsIdempotent() {
        let (store, _) = makeStore()
        var calls = 0
        store.migrateFromLegacyStateIfNeeded { agent in
            calls += 1
            return agent == .claudeCode
        }
        let firstCallCount = calls

        store.setIntent(.uninstalled, for: .claudeCode)

        store.migrateFromLegacyStateIfNeeded { _ in
            calls += 1
            return true
        }

        #expect(calls == firstCallCount, "second migration must not invoke detector")
        #expect(store.intent(for: .claudeCode) == .uninstalled, "user override must survive")
    }

    @Test
    func firstLaunchCompletedFlagRoundTrips() {
        let (store, defaults) = makeStore()

        #expect(store.firstLaunchCompleted == false)
        store.firstLaunchCompleted = true

        let reopened = AgentIntentStore(defaults: defaults)
        #expect(reopened.firstLaunchCompleted == true)
    }

    // MARK: - Helpers

    /// Creates a store backed by an ephemeral UserDefaults suite so each test
    /// gets a clean slate without touching production preferences.
    private func makeStore() -> (AgentIntentStore, UserDefaults) {
        let suiteName = "open-island-intent-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (AgentIntentStore(defaults: defaults), defaults)
    }
}
