import UIKit

// coverage-exempt-file: declarations only

/// Makes the security settings, the paywall and the migration screen.
@MainActor
protocol SettingsFactory: AnyObject {
    /// The security settings screen (in its navigation controller).
    func makeSettings() -> UIViewController
    /// The paywall; `onUnlock` runs after Pro is unlocked.
    func makePaywall(onUnlock: @escaping () -> Void) -> UIViewController
    /// The migration screen; `onFinish` reports whether the migration completed fully.
    func makeMigration(onFinish: @escaping (Bool) -> Void) -> UIViewController
}
