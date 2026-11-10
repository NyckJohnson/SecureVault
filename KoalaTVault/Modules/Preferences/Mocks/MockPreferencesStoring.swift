import Foundation
import os

/// In-memory preferences for previews and tests; records every write.
final class MockPreferencesStoring: PreferencesStoring {
    /// A recorded write.
    enum Write: Equatable, Sendable {
        case hasCompletedSetup(Bool)
        case lockMode(LockMode)
        case sortOption(SortOption)
        case sortDirection(SortDirection)
        case pendingMigration(PendingMigration?)
        case vaultsUpgraded(Bool)
    }

    private struct State: Sendable {
        var hasCompletedSetup: Bool
        var lockMode: LockMode
        var sortOption: SortOption
        var sortDirection: SortDirection
        var pendingMigration: PendingMigration?
        var vaultsUpgraded: Bool
        var writes: [Write] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    /// Preferences with the given values (the store's defaults unless stated).
    init(
        hasCompletedSetup: Bool = false,
        lockMode: LockMode = .none,
        sortOption: SortOption = .name,
        sortDirection: SortDirection = .ascending,
        pendingMigration: PendingMigration? = nil,
        vaultsUpgraded: Bool = false
    ) {
        state = OSAllocatedUnfairLock(
            initialState: State(
                hasCompletedSetup: hasCompletedSetup,
                lockMode: lockMode,
                sortOption: sortOption,
                sortDirection: sortDirection,
                pendingMigration: pendingMigration,
                vaultsUpgraded: vaultsUpgraded))
    }

    /// Every write so far, in order.
    var writes: [Write] { state.withLock { $0.writes } }

    var hasCompletedSetup: Bool {
        get { state.withLock { $0.hasCompletedSetup } }
        set {
            state.withLock {
                $0.hasCompletedSetup = newValue; $0.writes.append(.hasCompletedSetup(newValue))
            }
        }
    }

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

    var pendingMigration: PendingMigration? {
        get { state.withLock { $0.pendingMigration } }
        set {
            state.withLock {
                $0.pendingMigration = newValue; $0.writes.append(.pendingMigration(newValue))
            }
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
