import Foundation
import Testing

@testable import KoalaTVault

// Bulk and single-item operations of FileBrowserViewModel; the API is described in
// FileBrowserViewModelTests.swift.

@MainActor
@Suite struct FileBrowserViewModelBulkTests: FileBrowserTestSupport {
    // MARK: - Bulk delete

    @Test("Bulk delete asks Delete N items?")
    func bulkDeleteConfirmTitle() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        let three = try ["Beach.jpg", "Notes.rtf", "Holiday.mov"].map { try item($0, in: rig.store) }
        #expect(rig.viewModel.deleteConfirmation(for: three).title == "Delete 3 items?")
    }

    @Test("Delete moves every item to the trash and reloads")
    func deleteMovesToTrash() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        let two = try ["Beach.jpg", "Notes.rtf"].map { try item($0, in: rig.store) }
        await rig.viewModel.delete(two)
        #expect(rig.store.trashBatches == [two.map(\.id)])
        #expect(!rig.viewModel.items.map(\.name).contains("Beach.jpg"))
        #expect(!rig.viewModel.items.map(\.name).contains("Notes.rtf"))
        #expect(rig.alerts.alerts.isEmpty)
    }

    @Test("Bulk delete reports N of M failed when some fail and still deletes the rest")
    func deletePartialFailure() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        let items = [try item("Beach.jpg", in: rig.store), ghost("Missing.txt", store: rig.store)]
        await rig.viewModel.delete(items)
        #expect(rig.store.trashBatches == [items.map(\.id)])
        #expect(!rig.viewModel.items.map(\.name).contains("Beach.jpg"))
        #expect(errorMessages(rig.alerts).contains { $0.contains("1 of 2 failed") })
    }

    @Test("Bulk delete reports every item failing")
    func deleteAllFail() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        let items = [try item("Beach.jpg", in: rig.store), try item("Notes.rtf", in: rig.store)]
        rig.store.errorToThrow = .io("disk")
        await rig.viewModel.delete(items)
        #expect(errorMessages(rig.alerts).contains { $0.contains("2 of 2 failed") })
    }

    // MARK: - Bulk delete batching (large trash, 2026-11-13)

    /// Creates `count` empty documents in the store's root, in order.
    private func makeFiles(_ count: Int, in store: MockVaultStoring) async throws -> [VaultItem] {
        var items: [VaultItem] = []
        for index in 0..<count {
            items.append(try await store.createDocument(named: "File \(index).txt", in: store.root))
        }
        return items
    }

    @Test("Bulk delete uses the batch trash call and never the single-item one")
    func deleteUsesBatchCallOnly() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        let two = try ["Beach.jpg", "Notes.rtf"].map { try item($0, in: rig.store) }
        await rig.viewModel.delete(two)
        #expect(!rig.store.calls.contains { if case .moveToTrash = $0 { true } else { false } })
        #expect(rig.store.trashBatches.count == 1)
    }

    @Test("A selection is sent in selection order, not store order")
    func deleteKeepsSelectionOrder() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        let chosen = try ["Notes.rtf", "Beach.jpg", "Holiday.mov"].map { try item($0, in: rig.store) }
        await rig.viewModel.delete(chosen)
        #expect(rig.store.trashBatches == [chosen.map(\.id)])
    }

    @Test("Deleting nothing makes no store call and shows nothing")
    func deleteEmptySelection() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        await rig.viewModel.delete([])
        #expect(rig.store.trashBatches.isEmpty)
        #expect(rig.alerts.alerts.isEmpty)
    }

    @Test("Selections up to 256 items go in one batch", arguments: [1, 255, 256])
    func deleteSmallSelectionOneBatch(count: Int) async throws {
        let rig = try makeRig(withSampleContent: false)
        let items = try await makeFiles(count, in: rig.store)
        await rig.viewModel.load()
        await rig.viewModel.delete(items)
        #expect(rig.store.trashBatches == [items.map(\.id)])
        #expect(rig.alerts.alerts.isEmpty)
    }

    @Test("257 items go in batches of 256 and 1")
    func deleteJustOverOneBatch() async throws {
        let rig = try makeRig(withSampleContent: false)
        let items = try await makeFiles(257, in: rig.store)
        await rig.viewModel.load()
        await rig.viewModel.delete(items)
        #expect(rig.store.trashBatches.map(\.count) == [256, 1])
    }

    @Test("600 items go in batches of 256, 256 and 88, in selection order, then the grid reloads")
    func deleteLargeSelectionInBatches() async throws {
        let rig = try makeRig(withSampleContent: false)
        let items = try await makeFiles(600, in: rig.store)
        await rig.viewModel.load()
        #expect(rig.viewModel.items.count == 600)
        await rig.viewModel.delete(items)
        let batches = rig.store.trashBatches
        #expect(batches.map(\.count) == [256, 256, 88])
        #expect(batches.flatMap { $0 } == items.map(\.id))
        #expect(rig.viewModel.items.isEmpty)
        #expect(rig.alerts.alerts.isEmpty)
    }

    @Test("Failures from every batch are counted together as N of M")
    func deleteCountsFailuresAcrossBatches() async throws {
        let rig = try makeRig(withSampleContent: false)
        let items = try await makeFiles(600, in: rig.store)
        await rig.viewModel.load()
        rig.store.trashErrors = [
            items[10].id: .io("disk first"), items[300].id: .io("disk second"), items[590].id: .io("disk third"),
        ]
        await rig.viewModel.delete(items)
        let messages = errorMessages(rig.alerts)
        #expect(messages.count == 1)
        #expect(messages.first?.contains("3 of 600 failed") == true)
        #expect(rig.viewModel.items.count == 3)
    }

    @Test("The message shows the first failed item's error in selection order, even from a later batch")
    func deleteShowsFirstFailureFromLaterBatch() async throws {
        let rig = try makeRig(withSampleContent: false)
        let items = try await makeFiles(600, in: rig.store)
        await rig.viewModel.load()
        rig.store.trashErrors = [items[590].id: .io("disk late"), items[300].id: .io("disk middle")]
        await rig.viewModel.delete(items)
        let message = try #require(errorMessages(rig.alerts).first)
        #expect(message.contains("2 of 600 failed"))
        #expect(message.contains("disk middle"))
        #expect(!message.contains("disk late"))
    }

    @Test("The first failure is by selection order, not by the order of the returned errors")
    func deleteFirstFailureBySelectionOrder() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        let beach = try item("Beach.jpg", in: rig.store)
        let notes = try item("Notes.rtf", in: rig.store)
        let holiday = try item("Holiday.mov", in: rig.store)
        rig.store.trashErrors = [holiday.id: .io("disk holiday"), notes.id: .io("disk notes")]
        await rig.viewModel.delete([holiday, beach, notes])
        let message = try #require(errorMessages(rig.alerts).first)
        #expect(message.contains("2 of 3 failed"))
        #expect(message.contains("disk holiday"))
        #expect(!message.contains("disk notes"))
    }

    @Test("No failures means no failure message after a multi-batch delete")
    func deleteNoFailureMessage() async throws {
        let rig = try makeRig(withSampleContent: false)
        let items = try await makeFiles(300, in: rig.store)
        await rig.viewModel.load()
        await rig.viewModel.delete(items)
        #expect(errorMessages(rig.alerts).isEmpty)
    }

    // MARK: - Copy

    @Test("Copy puts a copy of each item into the current folder")
    func copyIntoCurrentFolder() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        await rig.viewModel.copy([try item("Beach.jpg", in: rig.store), try item("Notes.rtf", in: rig.store)])
        #expect(rig.store.calls.contains(.copy("Beach.jpg", destination: "")))
        #expect(rig.store.calls.contains(.copy("Notes.rtf", destination: "")))
        #expect(rig.viewModel.items.map(\.name).contains("Beach 1.jpg"))
    }

    @Test("Bulk copy reports N of M failed when some fail")
    func copyPartialFailure() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        let items = [
            try item("Beach.jpg", in: rig.store), ghost("A.txt", store: rig.store), ghost("B.txt", store: rig.store),
        ]
        await rig.viewModel.copy(items)
        #expect(errorMessages(rig.alerts).contains { $0.contains("2 of 3 failed") })
    }

    // MARK: - Export

    @Test("Export prepares the items and hands the bundle to the share sheet")
    func exportShares() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        let beach = try item("Beach.jpg", in: rig.store)
        await rig.viewModel.export([beach])
        #expect(rig.exporter.calls == [.prepareForSharing(["Beach.jpg"])])
        #expect(rig.recorder.shared == [[beach.diskURL]])
    }

    @Test("An export failure is shown and nothing is shared")
    func exportFailureShown() async throws {
        let rig = try makeRig()
        await rig.viewModel.export([])
        #expect(errorMessages(rig.alerts).count == 1)
        #expect(rig.recorder.shared.isEmpty)
    }

    // MARK: - Move and the picker

    @Test("Move asks for the picker with the items to move")
    func moveOpensPicker() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        rig.viewModel.beginMove([try item("Beach.jpg", in: rig.store), try item("Notes.rtf", in: rig.store)])
        #expect(rig.recorder.pickerRequests == [["Beach.jpg", "Notes.rtf"]])
    }

    @Test("The picker's choice moves exactly the pending items")
    func pickerChoiceMovesPending() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        let documents = try #require(try item("Documents", in: rig.store).asDirectory)
        rig.viewModel.beginMove([try item("Beach.jpg", in: rig.store), try item("Notes.rtf", in: rig.store)])
        await rig.viewModel.pickerChose(documents)
        let moves = rig.store.calls.filter { if case .move = $0 { true } else { false } }
        #expect(moves == [.move("Beach.jpg", destination: "Documents"), .move("Notes.rtf", destination: "Documents")])
        #expect(!rig.viewModel.items.map(\.name).contains("Beach.jpg"))
    }

    @Test("Only one move is pending at a time: a new move replaces the old")
    func newMoveReplacesPending() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        let documents = try #require(try item("Documents", in: rig.store).asDirectory)
        rig.viewModel.beginMove([try item("Beach.jpg", in: rig.store)])
        rig.viewModel.beginMove([try item("Notes.rtf", in: rig.store)])
        await rig.viewModel.pickerChose(documents)
        let moves = rig.store.calls.filter { if case .move = $0 { true } else { false } }
        #expect(moves == [.move("Notes.rtf", destination: "Documents")])
    }

    @Test("Cancelling the picker clears the pending move")
    func cancelClearsPendingMove() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        let documents = try #require(try item("Documents", in: rig.store).asDirectory)
        rig.viewModel.beginMove([try item("Beach.jpg", in: rig.store)])
        rig.viewModel.pickerCancelled()
        await rig.viewModel.pickerChose(documents)
        #expect(!rig.store.calls.contains { if case .move = $0 { true } else { false } })
    }

    @Test("After a cancel, the next move moves only its own items")
    func moveAfterCancelIgnoresOldSelection() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        let documents = try #require(try item("Documents", in: rig.store).asDirectory)
        rig.viewModel.beginMove([try item("Beach.jpg", in: rig.store), try item("Notes.rtf", in: rig.store)])
        rig.viewModel.pickerCancelled()
        rig.viewModel.beginMove([try item("Holiday.mov", in: rig.store)])
        await rig.viewModel.pickerChose(documents)
        let moves = rig.store.calls.filter { if case .move = $0 { true } else { false } }
        #expect(moves == [.move("Holiday.mov", destination: "Documents")])
    }

    @Test("A picker choice is used once; choosing again moves nothing")
    func pendingMoveConsumed() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        let documents = try #require(try item("Documents", in: rig.store).asDirectory)
        rig.viewModel.beginMove([try item("Beach.jpg", in: rig.store)])
        await rig.viewModel.pickerChose(documents)
        await rig.viewModel.pickerChose(documents)
        let moves = rig.store.calls.filter { if case .move = $0 { true } else { false } }
        #expect(moves.count == 1)
    }

    @Test("Bulk move reports N of M failed when some fail")
    func movePartialFailure() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        let documents = try #require(try item("Documents", in: rig.store).asDirectory)
        rig.viewModel.beginMove([try item("Beach.jpg", in: rig.store), ghost("Gone.txt", store: rig.store)])
        await rig.viewModel.pickerChose(documents)
        #expect(errorMessages(rig.alerts).contains { $0.contains("1 of 2 failed") })
    }

    @Test("Moving a folder into itself shows an error and moves nothing")
    func moveFolderIntoItselfShowsError() async throws {
        let rig = try makeRig()
        let photos = try item("Photos", in: rig.store)
        let inner = try await rig.store.createFolder(named: "Inner", in: try #require(photos.asDirectory))
        await rig.viewModel.load()
        rig.viewModel.beginMove([photos])
        await rig.viewModel.pickerChose(try #require(inner.asDirectory))
        #expect(!errorMessages(rig.alerts).isEmpty)
        #expect(try item("Photos", in: rig.store).diskURL == photos.diskURL)
    }

    // MARK: - Single-item failures show the item's own error

    @Test("A single failing delete shows that item's own error")
    func singleDeleteShowsOwnError() async throws {
        let rig = try makeRig()
        await rig.viewModel.delete([ghost("Gone.txt", store: rig.store)])
        #expect(errorMessages(rig.alerts) == [VaultStoreError.notFound.localizedDescription])
    }

    @Test("A single failing copy shows that item's own error")
    func singleCopyShowsOwnError() async throws {
        let rig = try makeRig()
        await rig.viewModel.copy([ghost("Gone.txt", store: rig.store)])
        #expect(errorMessages(rig.alerts) == [VaultStoreError.notFound.localizedDescription])
    }

    @Test("A single failing move shows that item's own error")
    func singleMoveShowsOwnError() async throws {
        let rig = try makeRig()
        let documents = try #require(try item("Documents", in: rig.store).asDirectory)
        rig.viewModel.beginMove([ghost("Gone.txt", store: rig.store)])
        await rig.viewModel.pickerChose(documents)
        #expect(errorMessages(rig.alerts) == [VaultStoreError.notFound.localizedDescription])
    }

    @Test("A single failure with a store error shows its message without N of M")
    func singleFailureHasNoCounts() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        let beach = try item("Beach.jpg", in: rig.store)
        rig.store.errorToThrow = .io("disk full")
        await rig.viewModel.delete([beach])
        let messages = errorMessages(rig.alerts)
        #expect(messages == ["disk full"])
        #expect(!messages.contains { $0.contains("of 1 failed") })
    }

    // MARK: - Bulk operations end select mode

    private func selectTwo(_ rig: FileBrowserRig) async throws -> [VaultItem] {
        await rig.viewModel.load()
        let chosen = [try item("Beach.jpg", in: rig.store), try item("Notes.rtf", in: rig.store)]
        rig.viewModel.toggleSelectMode()
        chosen.forEach { rig.viewModel.toggleSelection(of: $0) }
        return chosen
    }

    @Test("Bulk delete ends select mode and clears the selection")
    func deleteEndsSelectMode() async throws {
        let rig = try makeRig()
        await rig.viewModel.delete(try await selectTwo(rig))
        #expect(!rig.viewModel.isSelecting)
        #expect(rig.viewModel.selectedItems.isEmpty)
    }

    @Test("Bulk copy ends select mode and clears the selection")
    func copyEndsSelectMode() async throws {
        let rig = try makeRig()
        await rig.viewModel.copy(try await selectTwo(rig))
        #expect(!rig.viewModel.isSelecting)
        #expect(rig.viewModel.selectedItems.isEmpty)
    }

    @Test("Bulk move ends select mode and clears the selection")
    func moveEndsSelectMode() async throws {
        let rig = try makeRig()
        let documents = try #require(try item("Documents", in: rig.store).asDirectory)
        rig.viewModel.beginMove(try await selectTwo(rig))
        await rig.viewModel.pickerChose(documents)
        #expect(!rig.viewModel.isSelecting)
        #expect(rig.viewModel.selectedItems.isEmpty)
    }

    // MARK: - Cancellation

    private func trashCalls(_ store: MockVaultStoring) -> Int {
        store.calls.filter { if case .moveToTrash = $0 { true } else { false } }.count
    }

    @Test("Cancelling a bulk delete stops before the remaining batches and shows no failure")
    func cancelledBulkDeleteStops() async throws {
        let mock = MockVaultStoring()
        let gated = GatedVaultStore(mock, holding: .firstBatchMoveToTrash)
        let alerts = MockAlertPresenting()
        let viewModel = FileBrowserViewModel(
            directory: gated.root, store: gated, preferences: MockPreferencesStoring(),
            exporter: MockVaultExporting(), alerts: alerts,
            lock: MockVaultLocking(), transfer: MockVaultTransferring())
        await viewModel.load()
        let many = try await makeFiles(600, in: mock)
        let task = Task { await viewModel.delete(many) }
        // Bounded wait: a delete that never makes a batch call fails the test instead of hanging it.
        var spins = 0
        while gated.waitingCount == 0, spins < 200_000 {
            await Task.yield()
            spins += 1
        }
        #expect(gated.waitingCount == 1)
        task.cancel()
        gated.releaseAll()
        await task.value
        #expect(mock.trashBatches.count == 1)
        #expect(alerts.alerts.isEmpty)
    }

    private struct CancellingRig {
        let viewModel: FileBrowserViewModel
        let gated: GatedVaultStore
        let mock: MockVaultStoring
        let alerts: MockAlertPresenting
        var chosen: [VaultItem] {
            ["Beach.jpg", "Notes.rtf", "Documents"].compactMap { name in mock.allItems.first { $0.name == name } }
        }
    }

    private func cancellingRig() -> CancellingRig {
        let mock = MockVaultStoring(withSampleContent: true)
        let gated = GatedVaultStore(mock, cancellingMoveAndCopy: true)
        let alerts = MockAlertPresenting()
        let viewModel = FileBrowserViewModel(
            directory: gated.root, store: gated, preferences: MockPreferencesStoring(),
            exporter: MockVaultExporting(), alerts: alerts,
            lock: MockVaultLocking(), transfer: MockVaultTransferring())
        return CancellingRig(viewModel: viewModel, gated: gated, mock: mock, alerts: alerts)
    }

    @Test("A bulk move cancelled by the store stops, shows no failure, ends select mode and reloads")
    func cancelledBulkMoveStops() async throws {
        let rig = cancellingRig()
        let (viewModel, gated, mock, alerts) = (rig.viewModel, rig.gated, rig.mock, rig.alerts)
        await viewModel.load()
        let documents = try #require(try item("Documents", in: mock).asDirectory)
        let chosen = rig.chosen
        #expect(chosen.count == 3)
        viewModel.toggleSelectMode()
        chosen.forEach { viewModel.toggleSelection(of: $0) }
        viewModel.beginMove(chosen)
        let reloadsBefore = mock.calls.count
        await viewModel.pickerChose(documents)
        #expect(gated.moveCopyCalls == 1)
        #expect(alerts.alerts.isEmpty)
        #expect(!viewModel.isSelecting)
        #expect(viewModel.selectedItems.isEmpty)
        #expect(mock.calls.count > reloadsBefore)
    }

    @Test("A bulk copy cancelled by the store stops, shows no failure, ends select mode and reloads")
    func cancelledBulkCopyStops() async throws {
        let rig = cancellingRig()
        let (viewModel, gated, mock, alerts) = (rig.viewModel, rig.gated, rig.mock, rig.alerts)
        await viewModel.load()
        let chosen = rig.chosen
        #expect(chosen.count == 3)
        viewModel.toggleSelectMode()
        chosen.forEach { viewModel.toggleSelection(of: $0) }
        let reloadsBefore = mock.calls.count
        await viewModel.copy(chosen)
        #expect(gated.moveCopyCalls == 1)
        #expect(alerts.alerts.isEmpty)
        #expect(!viewModel.isSelecting)
        #expect(viewModel.selectedItems.isEmpty)
        #expect(mock.calls.count > reloadsBefore)
    }
}
