import Foundation
import Testing

@testable import KoalaTVault

// Feature multiple-vaults-duress-password: the root title, the Lock button and Move/Copy to Vault of
// FileBrowserViewModel; the API is described in FileBrowserViewModelTests.swift.

@MainActor
@Suite struct FileBrowserViewModelVaultTests: FileBrowserTestSupport {
    private func contentsCalls(_ store: MockVaultStoring) -> Int {
        store.calls.filter { if case .contents = $0 { true } else { false } }.count
    }

    private func openTarget(_ rig: FileBrowserRig) async throws -> OpenVault {
        try await rig.lock.openTransferTarget(password: "correct horse")
    }

    private func twoItems(_ rig: FileBrowserRig) throws -> [VaultItem] {
        [try item("Beach.jpg", in: rig.store), try item("Notes.rtf", in: rig.store)]
    }

    // MARK: - Title

    @Test("The root's title is the vault's name")
    func rootTitleIsVaultName() throws {
        let rig = try makeRig(encryptedStore: true, vaultName: "Work")
        #expect(rig.viewModel.title == "Work")
    }

    @Test("The unencrypted vault's root is titled with its name")
    func unencryptedRootTitle() throws {
        let rig = try makeRig()
        #expect(rig.viewModel.title == rig.store.root.name)
    }

    // MARK: - Lock button

    @Test("The Lock button shows at the root of an encrypted vault")
    func lockButtonInEncryptedRoot() throws {
        let rig = try makeRig(encryptedStore: true, vaultName: "Work")
        #expect(rig.viewModel.showsLockButton)
    }

    @Test("The Lock button shows at the root of the unencrypted vault")
    func lockButtonInUnencryptedRoot() throws {
        let rig = try makeRig(encryptedStore: false)
        #expect(rig.viewModel.showsLockButton)
    }

    @Test("The Lock button does not show in a subfolder", arguments: [true, false])
    func lockButtonHiddenInSubfolder(encrypted: Bool) throws {
        let rig = try makeRig(inFolder: "Photos", encryptedStore: encrypted)
        #expect(!rig.viewModel.showsLockButton)
    }

    @Test("Tapping Lock at the root asks for the lock route", arguments: [true, false])
    func lockTappedRoutesToLock(encrypted: Bool) throws {
        let rig = try makeRig(encryptedStore: encrypted)
        rig.viewModel.lockTapped()
        #expect(rig.recorder.routes == [.lock])
    }

    @Test("Tapping Lock in a subfolder does nothing")
    func lockTappedInSubfolderIgnored() throws {
        let rig = try makeRig(inFolder: "Photos")
        rig.viewModel.lockTapped()
        #expect(rig.recorder.routes.isEmpty)
    }

    // MARK: - Entries lead to the vault picker

    @Test("The context menu offers Move to Vault and Copy to Vault")
    func contextMenuHasVaultEntries() throws {
        let rig = try makeRig()
        let actions = rig.viewModel.contextActions(for: try item("Beach.jpg", in: rig.store))
        #expect(actions.contains(.moveToVault))
        #expect(actions.contains(.copyToVault))
    }

    @Test("Move to Vault opens the vault picker for a move, Copy to Vault for a copy", arguments: [true, false])
    func beginTransferOpensPicker(isMove: Bool) throws {
        let rig = try makeRig()
        rig.viewModel.beginVaultTransfer(try twoItems(rig), isMove: isMove)
        #expect(rig.recorder.vaultPickerRequests == [isMove])
    }

    @Test("Beginning a transfer with no items does not open the picker")
    func beginTransferWithNothingIgnored() throws {
        let rig = try makeRig()
        rig.viewModel.beginVaultTransfer([], isMove: true)
        #expect(rig.recorder.vaultPickerRequests.isEmpty)
    }

    // MARK: - Transfer

    @Test("A chosen target moves the items from this store to the target's store, removing the originals")
    func moveTransfersRemovingOriginals() async throws {
        let rig = try makeRig()
        let items = try twoItems(rig)
        rig.viewModel.beginVaultTransfer(items, isMove: true)
        let target = try await openTarget(rig)
        await rig.viewModel.vaultPickerFinished(target)
        #expect(
            rig.transfer.calls == [
                .init(itemIDs: items.map(\.id), source: "KoalaTVault", target: "My Vault", removingOriginals: true)
            ])
    }

    @Test("A chosen target copies the items keeping the originals")
    func copyTransfersKeepingOriginals() async throws {
        let rig = try makeRig()
        let items = try twoItems(rig)
        rig.viewModel.beginVaultTransfer(items, isMove: false)
        let target = try await openTarget(rig)
        await rig.viewModel.vaultPickerFinished(target)
        #expect(
            rig.transfer.calls == [
                .init(itemIDs: items.map(\.id), source: "KoalaTVault", target: "My Vault", removingOriginals: false)
            ])
    }

    @Test("A transfer from an encrypted vault names the open vault as the source")
    func transferSourceIsOpenVault() async throws {
        let rig = try makeRig(encryptedStore: true, vaultName: "Work")
        rig.viewModel.beginVaultTransfer(try twoItems(rig), isMove: true)
        await rig.viewModel.vaultPickerFinished(rig.lock.unencryptedVault)
        #expect(rig.transfer.calls.map(\.source) == ["Work"])
        #expect(rig.transfer.calls.map(\.target) == ["KoalaTVault"])
    }

    @Test("A move shows Moving… progress and a copy shows Copying…, ending with nil", arguments: [true, false])
    func progressTitle(isMove: Bool) async throws {
        let rig = try makeRig()
        rig.viewModel.beginVaultTransfer(try twoItems(rig), isMove: isMove)
        await rig.viewModel.vaultPickerFinished(try await openTarget(rig))
        let reports = rig.recorder.progress
        let expected = isMove ? "Moving…" : "Copying…"
        #expect(reports.first == .some(.init(title: expected, done: 0, total: 2)))
        #expect(reports.last == .some(nil))
        #expect(reports.compactMap { $0 }.allSatisfy { $0.title == expected })
    }

    @Test("Progress reports N of M while the transfer runs")
    func progressReportsCounts() async throws {
        let held = HeldTransfer()
        let rig = try makeRig(transfer: held)
        let items = try ["Beach.jpg", "Holiday.mov", "Notes.rtf"].map { try item($0, in: rig.store) }
        rig.viewModel.beginVaultTransfer(items, isMove: true)
        let target = try await openTarget(rig)
        let task = Task { await rig.viewModel.vaultPickerFinished(target) }
        while !held.isWaiting { await Task.yield() }
        var spins = 0
        while !rig.recorder.progress.contains(where: { $0?.done == 2 }) && spins < 1000 {
            await Task.yield()
            spins += 1
        }
        let reported = rig.recorder.progress.compactMap { $0 }.first { $0.done == 2 }
        #expect(reported == .init(title: "Moving…", done: 2, total: 3))
        #expect(reported?.status == "2 of 3")
        held.release()
        await task.value
    }

    @Test("Only one transfer runs at a time")
    func oneTransferAtATime() async throws {
        let held = HeldTransfer()
        let rig = try makeRig(transfer: held)
        let items = try twoItems(rig)
        rig.viewModel.beginVaultTransfer(items, isMove: true)
        let target = try await openTarget(rig)
        let task = Task { await rig.viewModel.vaultPickerFinished(target) }
        while !held.isWaiting { await Task.yield() }
        rig.viewModel.beginVaultTransfer(items, isMove: false)
        #expect(rig.recorder.vaultPickerRequests == [true])
        held.release()
        await task.value
        #expect(held.calls == 1)
    }

    @Test("An encrypted target is closed after the transfer")
    func encryptedTargetClosed() async throws {
        let rig = try makeRig()
        rig.viewModel.beginVaultTransfer(try twoItems(rig), isMove: true)
        let target = try await openTarget(rig)
        await rig.viewModel.vaultPickerFinished(target)
        #expect(rig.lock.calls.contains(.closeTransferTarget(target.id)))
    }

    @Test("The unencrypted vault is never closed as a target")
    func unencryptedTargetNotClosed() async throws {
        let rig = try makeRig(encryptedStore: true, vaultName: "Work")
        rig.viewModel.beginVaultTransfer(try twoItems(rig), isMove: true)
        await rig.viewModel.vaultPickerFinished(rig.lock.unencryptedVault)
        #expect(!rig.lock.calls.contains { if case .closeTransferTarget = $0 { true } else { false } })
        #expect(rig.transfer.calls.count == 1)
    }

    @Test("After a transfer the grid reloads and select mode ends")
    func reloadsAfterTransfer() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        let before = contentsCalls(rig.store)
        let items = try twoItems(rig)
        rig.viewModel.toggleSelectMode()
        items.forEach { rig.viewModel.toggleSelection(of: $0) }
        rig.viewModel.beginVaultTransfer(items, isMove: true)
        await rig.viewModel.vaultPickerFinished(try await openTarget(rig))
        #expect(contentsCalls(rig.store) == before + 1)
        #expect(!rig.viewModel.isSelecting)
        #expect(rig.viewModel.selectedItems.isEmpty)
        #expect(rig.alerts.alerts.isEmpty)
    }

    @Test("A successful transfer shows no alert and no paywall")
    func successIsQuiet() async throws {
        let rig = try makeRig()
        rig.viewModel.beginVaultTransfer(try twoItems(rig), isMove: false)
        await rig.viewModel.vaultPickerFinished(try await openTarget(rig))
        #expect(rig.alerts.alerts.isEmpty)
        #expect(rig.recorder.needsProCount == 0)
    }

    // MARK: - Errors

    @Test("The free tier's limit opens the paywall without an alert")
    func limitReachedOpensPaywall() async throws {
        let rig = try makeRig()
        rig.transfer.errorToThrow = .limitReached
        rig.viewModel.beginVaultTransfer(try twoItems(rig), isMove: true)
        await rig.viewModel.vaultPickerFinished(try await openTarget(rig))
        #expect(rig.recorder.needsProCount == 1)
        #expect(rig.alerts.alerts.isEmpty)
        #expect(rig.recorder.progress.last == .some(nil))
    }

    @Test("Items that fail show N of M failed")
    func failedItemsShowCount() async throws {
        let rig = try makeRig()
        let items = try ["Beach.jpg", "Holiday.mov", "Notes.rtf"].map { try item($0, in: rig.store) }
        rig.transfer.failingIDs = [items[0].id]
        rig.viewModel.beginVaultTransfer(items, isMove: true)
        await rig.viewModel.vaultPickerFinished(try await openTarget(rig))
        let messages = errorMessages(rig.alerts)
        #expect(messages.count == 1)
        #expect(messages.first?.hasPrefix("1 of 3 failed") == true)
        #expect(rig.recorder.needsProCount == 0)
    }

    @Test("Another error shows its message")
    func otherErrorShowsMessage() async throws {
        let rig = try makeRig()
        rig.transfer.errorToThrow = .sameVault
        rig.viewModel.beginVaultTransfer(try twoItems(rig), isMove: true)
        await rig.viewModel.vaultPickerFinished(try await openTarget(rig))
        let expected = try #require(VaultTransferError.sameVault.errorDescription)
        #expect(errorMessages(rig.alerts) == [expected])
        #expect(rig.recorder.needsProCount == 0)
    }

    // MARK: - Cancel

    @Test("A cancelled picker starts no transfer")
    func cancelledPickerNoTransfer() async throws {
        let rig = try makeRig()
        rig.viewModel.beginVaultTransfer(try twoItems(rig), isMove: true)
        await rig.viewModel.vaultPickerFinished(nil)
        #expect(rig.transfer.calls.isEmpty)
        #expect(rig.alerts.alerts.isEmpty)
    }

    @Test("A cancelled picker clears the pending transfer")
    func cancelledPickerClearsPending() async throws {
        let rig = try makeRig()
        rig.viewModel.beginVaultTransfer(try twoItems(rig), isMove: true)
        await rig.viewModel.vaultPickerFinished(nil)
        await rig.viewModel.vaultPickerFinished(try await openTarget(rig))
        #expect(rig.transfer.calls.isEmpty)
    }

    @Test("A picker dismissed without a choice clears the pending transfer")
    func dismissedPickerClearsPending() async throws {
        let rig = try makeRig()
        rig.viewModel.beginVaultTransfer(try twoItems(rig), isMove: true)
        rig.viewModel.vaultPickerCancelled()
        await rig.viewModel.vaultPickerFinished(try await openTarget(rig))
        #expect(rig.transfer.calls.isEmpty)
    }
}
