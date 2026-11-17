import Foundation
import os

/// In-memory preferences for previews and tests; records every write.
final class MockPreferencesStoring: PreferencesStoring {
    /// A recorded write.
    enum Write: Equatable, Sendable {
        case lockMode(LockMode)
        case sortOption(SortOption)
        case sortDirection(SortDirection)
        case clearPendingMigration
        case vaultsUpgraded(Bool)
    }

    private struct State: Sendable {
        var lockMode: LockMode
        var sortOption: SortOption
        var sortDirection: SortDirection
        var hasPendingEncryptMigration: Bool
        var clearPendingMigrationCallCount = 0
        var vaultsUpgraded: Bool
        var writes: [Write] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    /// Preferences with the given values (the store's defaults unless stated).
    init(
        lockMode: LockMode = .none,
        sortOption: SortOption = .name,
        sortDirection: SortDirection = .ascending,
        hasPendingEncryptMigration: Bool = false,
        vaultsUpgraded: Bool = false
    ) {
        state = OSAllocatedUnfairLock(
            initialState: State(
                lockMode: lockMode,
                sortOption: sortOption,
                sortDirection: sortDirection,
                hasPendingEncryptMigration: hasPendingEncryptMigration,
                vaultsUpgraded: vaultsUpgraded))
    }

    /// Every write so far, in order.
    var writes: [Write] { state.withLock { $0.writes } }

    var lockMode: LockMode {
        get { state.withLock { $0.lockMode } }
        set {
            state.withLock {
                $0.lockMode = newValue; $0.writes.append(.lockMode(newValue))
            }
        }
    }

    var sortOption: SortOption {
        get { state.withLock { $0.sortOption } }
        set {
            state.withLock {
                $0.sortOption = newValue; $0.writes.append(.sortOption(newValue))
            }
        }
    }

    var sortDirection: SortDirection {
        get { state.withLock { $0.sortDirection } }
        set {
            state.withLock {
                $0.sortDirection = newValue; $0.writes.append(.sortDirection(newValue))
            }
        }
    }

    /// Settable by tests and previews to stand for a pending encrypt left by 1.2 (not recorded as a write).
    var hasPendingEncryptMigration: Bool {
        get { state.withLock { $0.hasPendingEncryptMigration } }
        set { state.withLock { $0.hasPendingEncryptMigration = newValue } }
    }

    /// How many times `clearPendingMigration()` was called.
    var clearPendingMigrationCallCount: Int { state.withLock { $0.clearPendingMigrationCallCount } }

    func clearPendingMigration() {
        state.withLock {
            $0.hasPendingEncryptMigration = false
            $0.clearPendingMigrationCallCount += 1
            $0.writes.append(.clearPendingMigration)
        }
    }

    var vaultsUpgraded: Bool {
        get { state.withLock { $0.vaultsUpgraded } }
        set {
            state.withLock {
                $0.vaultsUpgraded = newValue; $0.writes.append(.vaultsUpgraded(newValue))
            }
        }
    }
}
