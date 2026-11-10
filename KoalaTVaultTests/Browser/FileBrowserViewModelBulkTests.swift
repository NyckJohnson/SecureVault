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
        #expect(rig.store.calls.contains(.moveToTrash("Beach.jpg")))
        #expect(rig.store.calls.contains(.moveToTrash("Notes.rtf")))
        #expect(!rig.viewModel.items.map(\.name).contains("Beach.jpg"))
        #expect(rig.alerts.alerts.isEmpty)
    }

    @Test("Bulk delete reports N of M failed when some fail and still deletes the rest")
    func deletePartialFailure() async throws {
        let rig = try makeRig()
        await rig.viewModel.load()
        let items = [try item("Beach.jpg", in: rig.store), ghost("Missing.txt", store: rig.store)]
        await rig.viewModel.delete(items)
        #expect(rig.store.calls.contains(.moveToTrash("Beach.jpg")))
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

    @Test("Cancelling a bulk delete stops before the remaining items and shows no failure")
    func cancelledBulkDeleteStops() async throws {
        let mock = MockVaultStoring()
        let gated = GatedVaultStore(mock, holding: .firstMoveToTrash)
        let alerts = MockAlertPresenting()
        let viewModel = FileBrowserViewModel(
            directory: gated.root, store: gated, preferences: MockPreferencesStoring(),
            exporter: MockVaultExporting(), alerts: alerts)
        await viewModel.load()
        let three = try ["Beach.jpg", "Holiday.mov", "Notes.rtf"].map { try item($0, in: mock) }
        let task = Task { await viewModel.delete(three) }
        while gated.waitingCount == 0 { await Task.yield() }
        task.cancel()
        gated.releaseAll()
        await task.value
        #expect(trashCalls(mock) == 1)
        #expect(alerts.alerts.isEmpty)
    }

    @Test("A cancellation error from the store is not counted as a failure and stops the rest")
    func cancellationErrorNotAFailure() async throws {
        let mock = MockVaultStoring()
        let gated = GatedVaultStore(mock, holding: .firstMoveToTrash, cancelAfterHold: true)
        let alerts = MockAlertPresenting()
        let viewModel = FileBrowserViewModel(
            directory: gated.root, store: gated, preferences: MockPreferencesStoring(),
            exporter: MockVaultExporting(), alerts: alerts)
        await viewModel.load()
        let three = try ["Beach.jpg", "Holiday.mov", "Notes.rtf"].map { try item($0, in: mock) }
        let task = Task { await viewModel.delete(three) }
        while gated.waitingCount == 0 { await Task.yield() }
        task.cancel()
        gated.releaseAll()
        await task.value
        #expect(trashCalls(mock) == 0)
        #expect(alerts.alerts.isEmpty)
    }
}
