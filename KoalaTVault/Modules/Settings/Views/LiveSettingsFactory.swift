import UIKit

/// Makes the real security settings, paywall and migration screens.
@MainActor
final class LiveSettingsFactory: SettingsFactory {
    private let lock: any VaultLocking
    private let migrator: any LockMigrating
    private let store: any VaultStoring
    private let pro: any ProUnlocking
    private let onRestore: @MainActor () -> Void

    /// - Parameters:
    ///   - lock: the vaults; Settings is for the vault open when it is made (the shell makes a factory per vault).
    ///   - migrator: the leftover encryption the migration screen follows.
    ///   - store: the open vault's store (Recently Deleted).
    ///   - pro: the "Unlock Pro" entitlement.
    ///   - onRestore: called after Recently Deleted (inside the settings screen) restores an item, so the
    ///     browser can refresh; `makeSettings()` has no callback of its own.
    init(
        lock: any VaultLocking, migrator: any LockMigrating, store: any VaultStoring, pro: any ProUnlocking,
        onRestore: @escaping @MainActor () -> Void
    ) {
        self.lock = lock
        self.migrator = migrator
        self.store = store
        self.pro = pro
        self.onRestore = onRestore
    }

    /// The security settings in a navigation controller, shown as a form sheet.
    func makeSettings() -> UIViewController {
        let settings = SecuritySettingsViewController(lock: lock, store: store, pro: pro, onRestore: onRestore)
        let navigation = UINavigationController(rootViewController: settings)
        navigation.modalPresentationStyle = .formSheet
        return navigation
    }

    /// The paywall, shown as a form sheet.
    func makePaywall(onUnlock: @escaping () -> Void) -> UIViewController {
        let callback = MainActorCallback(onUnlock)
        let paywall = PaywallViewController(pro: pro, onUnlock: { callback.action(()) })
        paywall.modalPresentationStyle = .formSheet
        return paywall
    }

    /// The "Encrypting Files" screen, full screen. The caller starts the encryption (`encryptLeftovers(in:)`)
    /// once the screen is shown, so a `.completed` phase left by an earlier run is not taken for this one's end.
    func makeMigration(onFinish: @escaping (Bool) -> Void) -> UIViewController {
        let callback = MainActorCallback(onFinish)
        return MigrationViewController(
            migrator: migrator, waitsForNewRun: true, onFinish: { callback.action($0) })
    }
}

/// Holds one of the contract's plain callbacks on the main actor, so a `@MainActor` closure (which must be
/// `Sendable`) can call it: the contract is main-actor isolated, so its callbacks are only ever called there.
@MainActor
private final class MainActorCallback<Value> {
    let action: (Value) -> Void

    init(_ action: @escaping (Value) -> Void) {
        self.action = action
    }
}
