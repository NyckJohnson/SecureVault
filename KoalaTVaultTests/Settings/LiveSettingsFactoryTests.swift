import Testing
import UIKit

@testable import KoalaTVault

/// `LiveSettingsFactory(lock:migrator:store:pro:onRestore:)` conforming to `SettingsFactory`.
@MainActor
@Suite struct LiveSettingsFactoryTests {
    private struct Rig {
        let factory: LiveSettingsFactory
        let migrator: SettingsScriptedMigrator
        let store: MockVaultStoring
        let pro: MockProUnlocking
        let restored: SettingsRecorder<Void>
    }

    private func makeRig(pending: PendingMigration? = nil, store: MockVaultStoring? = nil) -> Rig {
        let migrator = SettingsScriptedMigrator()
        migrator.pending = pending
        let store = store ?? MockVaultStoring(withSampleContent: false)
        let pro = MockProUnlocking(isUnlocked: false)
        let restored = SettingsRecorder<Void>()
        let factory = LiveSettingsFactory(
            lock: MockVaultLocking(), migrator: migrator, store: store, pro: pro,
            onRestore: { restored.record(()) })
        return Rig(factory: factory, migrator: migrator, store: store, pro: pro, restored: restored)
    }

    @Test("makeSettings returns a form-sheet navigation controller rooted at the security settings")
    func settingsIsNavigationFormSheet() throws {
        let screen = makeRig().factory.makeSettings()
        let navigation = try #require(screen as? UINavigationController)
        #expect(navigation.viewControllers.first is SecuritySettingsViewController)
        #expect(navigation.modalPresentationStyle == .formSheet)
    }

    @Test("makePaywall returns a form-sheet paywall")
    func paywallIsFormSheet() {
        let screen = makeRig().factory.makePaywall(onUnlock: {})
        #expect(screen is PaywallViewController)
        #expect(screen.modalPresentationStyle == .formSheet)
    }

    @Test("Unlocking in the paywall calls onUnlock")
    func paywallUnlockCallsOnUnlock() async {
        let rig = makeRig()
        rig.pro.purchaseOutcome = .unlocked
        let unlocked = SettingsRecorder<Void>()
        let screen = rig.factory.makePaywall(onUnlock: { unlocked.record(()) })
        let host = SettingsViewHost.presenting(screen)
        host.tap("paywallUnlockButton")
        await SettingsTestSupport.waitUntil { !unlocked.values.isEmpty }
        #expect(unlocked.values.count == 1)
    }

    @Test("makeMigration is titled Decrypting Files when a decrypt migration is pending")
    func migrationUsesPendingDecrypt() {
        let rig = makeRig(pending: PendingMigration(kind: .decrypt, targetLockMode: nil))
        let host = SettingsViewHost.presenting(rig.factory.makeMigration(onFinish: { _ in }))
        #expect((host.element("migration.titleLabel") as? UILabel)?.text == "Decrypting Files")
    }

    @Test("makeMigration is titled Encrypting Files when a migration is pending encrypt")
    func migrationUsesPendingEncrypt() {
        let rig = makeRig(pending: PendingMigration(kind: .encrypt, targetLockMode: .password))
        let host = SettingsViewHost.presenting(rig.factory.makeMigration(onFinish: { _ in }))
        #expect((host.element("migration.titleLabel") as? UILabel)?.text == "Encrypting Files")
    }

    @Test("makeMigration is titled Encrypting Files when no migration is pending")
    func migrationDefaultsToEncrypt() {
        let rig = makeRig(pending: nil)
        let host = SettingsViewHost.presenting(rig.factory.makeMigration(onFinish: { _ in }))
        #expect((host.element("migration.titleLabel") as? UILabel)?.text == "Encrypting Files")
    }

    @Test("Finishing the migration calls onFinish with the completed flag", arguments: [true, false])
    func migrationFinishReportsFlag(fully: Bool) async {
        let rig = makeRig()
        let finished = SettingsRecorder<Bool>()
        let host = SettingsViewHost.presenting(rig.factory.makeMigration(onFinish: { finished.record($0) }))
        await SettingsTestSupport.waitUntil { rig.migrator.calls.contains(.phaseUpdates) }
        rig.migrator.send(.running(done: 1, total: 2))
        await SettingsTestSupport.settle()
        rig.migrator.send(.completed(fully: fully))
        await SettingsTestSupport.waitUntil { !finished.values.isEmpty }
        #expect(finished.values == [fully])
        withExtendedLifetime(host) {}
    }

    @Test("Restoring from Recently Deleted inside the settings calls the factory's onRestore")
    func restoreCallsOnRestore() async throws {
        let store = MockVaultStoring(withSampleContent: false)
        let source = URL(fileURLWithPath: "/nonexistent/source")
        let item = try await store.addFile(from: source, named: "a.txt", to: store.root)
        try await store.moveToTrash(item)
        let rig = makeRig(store: store)
        let host = SettingsViewHost(content: rig.factory.makeSettings())
        await SettingsTestSupport.waitUntil { host.element("settings.recentlyDeletedRow") != nil }
        host.selectRow("settings.recentlyDeletedRow", inTable: "settings.table")
        await SettingsTestSupport.waitUntil { host.element("recentlyDeleted.row.a.txt") != nil }
        host.selectRow("recentlyDeleted.row.a.txt", inTable: "recentlyDeleted.list")
        let sheet = try #require(await host.alert())
        sheet.fire("Restore")
        await SettingsTestSupport.waitUntil { !rig.restored.values.isEmpty }
        #expect(rig.restored.values.count == 1)
    }
}
