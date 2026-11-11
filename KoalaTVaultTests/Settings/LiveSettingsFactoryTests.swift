import Testing
import UIKit

@testable import KoalaTVault

/// `LiveSettingsFactory(lock:migrator:store:pro:onRestore:)` conforming to `SettingsFactory`; Settings is for the vault
/// current when it is made, and the migration screen only encrypts leftovers and waits for a new run.
@MainActor
@Suite struct LiveSettingsFactoryTests {
    private struct Rig {
        let factory: LiveSettingsFactory
        let migrator: SettingsScriptedMigrator
        let store: MockVaultStoring
        let pro: MockProUnlocking
        let restored: SettingsRecorder<Void>
    }

    private func makeRig(store: MockVaultStoring? = nil, lock: MockVaultLocking = MockVaultLocking()) -> Rig {
        let migrator = SettingsScriptedMigrator()
        let store = store ?? MockVaultStoring(withSampleContent: false)
        let pro = MockProUnlocking(isUnlocked: false)
        let restored = SettingsRecorder<Void>()
        let factory = LiveSettingsFactory(
            lock: lock, migrator: migrator, store: store, pro: pro,
            onRestore: { restored.record(()) })
        return Rig(factory: factory, migrator: migrator, store: store, pro: pro, restored: restored)
    }

    @Test(
        "makeSettings returns a form-sheet navigation controller rooted at the security settings")
    func settingsIsNavigationFormSheet() throws {
        let screen = makeRig().factory.makeSettings()
        let navigation = try #require(screen as? UINavigationController)
        #expect(navigation.viewControllers.first is SecuritySettingsViewController)
        #expect(navigation.modalPresentationStyle == .formSheet)
    }

    @Test("makeSettings builds Settings for the encrypted vault current at the time, titled with its name")
    func settingsForCurrentEncryptedVault() async throws {
        let lock = MockVaultLocking()
        try await lock.open(password: "correct horse")
        let rig = makeRig(lock: lock)
        let host = SettingsViewHost.presenting(rig.factory.makeSettings())
        await SettingsTestSupport.waitUntil { host.element("settings.deleteVaultRow") != nil }
        #expect(host.element("settings.changePasswordRow") != nil)
        let table = try #require(host.element("settings.table") as? UITableView)
        let titles = (0..<table.numberOfSections).map {
            table.dataSource?.tableView?(table, titleForHeaderInSection: $0)
        }
        #expect(titles.contains { $0 == "My Vault" })
    }

    @Test("makeSettings for the unencrypted vault has no Vault section rows")
    func settingsForUnencryptedVault() async {
        let rig = makeRig()
        let host = SettingsViewHost.presenting(rig.factory.makeSettings())
        await SettingsTestSupport.waitUntil { host.element("upgradeToProCell") != nil }
        await SettingsTestSupport.settle()
        #expect(host.element("settings.changePasswordRow") == nil)
        #expect(host.element("settings.deleteVaultRow") == nil)
    }

    @Test("A migration screen that already holds a completed phase does not finish until a new run completes")
    func migrationWaitsForNewRun() async {
        let migrator = SettingsScriptedMigrator(phase: .completed(fully: true))
        let finished = SettingsRecorder<Bool>()
        let factory = LiveSettingsFactory(
            lock: MockVaultLocking(), migrator: migrator, store: MockVaultStoring(withSampleContent: false),
            pro: MockProUnlocking(isUnlocked: false), onRestore: {})
        let host = SettingsViewHost.presenting(factory.makeMigration(onFinish: { finished.record($0) }))
        await SettingsTestSupport.waitUntil { migrator.calls.contains(.phaseUpdates) }
        await SettingsTestSupport.settle()
        #expect((host.element("migration.statusLabel") as? UILabel)?.text != "Complete")
        #expect(finished.values.isEmpty)
        migrator.send(.running(done: 1, total: 2))
        await SettingsTestSupport.settle()
        migrator.send(.completed(fully: true))
        await SettingsTestSupport.waitUntil { !finished.values.isEmpty }
        #expect(finished.values == [true])
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

    @Test(
        "makeMigration is titled Encrypting Files")
    func migrationDefaultsToEncrypt() {
        let rig = makeRig()
        let host = SettingsViewHost.presenting(rig.factory.makeMigration(onFinish: { _ in }))
        #expect((host.element("migration.titleLabel") as? UILabel)?.text == "Encrypting Files")
    }

    @Test(
        "Finishing the migration calls onFinish with the completed flag", arguments: [true, false])
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

    @Test(
        "Restoring from Recently Deleted inside the settings calls the factory's onRestore")
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
