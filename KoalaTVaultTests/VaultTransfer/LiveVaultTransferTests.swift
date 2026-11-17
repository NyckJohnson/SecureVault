import Foundation
import Testing
import os

@testable import KoalaTVault

@MainActor
@Suite struct LiveVaultTransferTests {
    @discardableResult
    private func run(
        _ fixture: TransferFixture, ids: [String], removing: Bool, pro: Bool = true,
        progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> TransferResult {
        let items = try ids.map { try #require(fixture.source.item($0)) }
        return try await makeTransfer(pro: pro).transfer(
            items, from: fixture.source, to: fixture.target, removingOriginals: removing, progress: progress)
    }

    // MARK: - Files

    @Test("A copied file lands in the target's root and stays in the source")
    func copyFileToRoot() async throws {
        let fixture = TransferFixture()
        let result = try await run(fixture, ids: ["Beach.jpg"], removing: false)
        #expect(result == TransferResult(done: 1, failed: 0))
        #expect(fixture.target.item("Beach.jpg") != nil)
        #expect(fixture.source.item("Beach.jpg") != nil)
        #expect(fixture.target.inner.calls.contains(.addFile("Beach.jpg", destination: "")))
    }

    @Test("A moved file lands in the target and is removed from the source")
    func moveFileRemovesOriginal() async throws {
        let fixture = TransferFixture()
        let result = try await run(fixture, ids: ["Beach.jpg"], removing: true)
        #expect(result == TransferResult(done: 1, failed: 0))
        #expect(fixture.target.item("Beach.jpg") != nil)
        #expect(fixture.source.item("Beach.jpg") == nil)
    }

    @Test("Each file is opened from the source, then added to the target, then the original is removed")
    func openThenAddThenRemove() async throws {
        let fixture = TransferFixture()
        try await run(fixture, ids: ["Beach.jpg"], removing: true)
        let open = try #require(fixture.log.index(of: "src.open:Beach.jpg"))
        let add = try #require(fixture.log.index(of: "tgt.addFile:Beach.jpg"))
        let remove = try #require(fixture.log.index(of: "src.remove:Beach.jpg"))
        #expect(open < add)
        #expect(add < remove)
    }

    @Test("Items are transferred in the order given")
    func itemsInOrder() async throws {
        let fixture = TransferFixture()
        try await run(fixture, ids: ["Notes.rtf", "Beach.jpg", "Holiday.mov"], removing: false)
        let adds = fixture.log.events.filter { $0.hasPrefix("tgt.addFile:") }
        #expect(adds == ["tgt.addFile:Notes.rtf", "tgt.addFile:Beach.jpg", "tgt.addFile:Holiday.mov"])
    }

    @Test("A name that clashes in the target gets \" 1\"")
    func clashingNameGetsSuffix() async throws {
        let fixture = TransferFixture()
        _ = try await fixture.target.inner.addFile(
            from: URL(fileURLWithPath: "/dev/null"), named: "Beach.jpg", to: fixture.target.root)
        let result = try await run(fixture, ids: ["Beach.jpg"], removing: false)
        #expect(result == TransferResult(done: 1, failed: 0))
        #expect(fixture.target.item("Beach.jpg") != nil)
        #expect(fixture.target.item("Beach 1.jpg") != nil)
    }

    @Test("An empty list of items does nothing and reports zero")
    func emptyItems() async throws {
        let fixture = TransferFixture()
        let result = try await run(fixture, ids: [], removing: true)
        #expect(result == TransferResult(done: 0, failed: 0))
        #expect(fixture.log.events.filter { $0.hasPrefix("tgt.") }.isEmpty)
    }

    // MARK: - Folders

    @Test("A copied folder is recreated in the target with all its files, and stays in the source")
    func copyFolder() async throws {
        let fixture = TransferFixture()
        let result = try await run(fixture, ids: ["Photos"], removing: false)
        #expect(result == TransferResult(done: 1, failed: 0))
        #expect(fixture.target.itemIDs.isSuperset(of: ["Photos", "Photos/Sunset.heic", "Photos/Birthday.mp4"]))
        #expect(fixture.target.item("Photos")?.isDirectory == true)
        #expect(fixture.source.itemIDs.isSuperset(of: ["Photos", "Photos/Sunset.heic", "Photos/Birthday.mp4"]))
        #expect(fixture.log.events.contains("tgt.createFolder:Photos"))
    }

    @Test("A moved folder is removed from the source after everything in it was copied")
    func moveFolderRemovesAfterContents() async throws {
        let fixture = TransferFixture()
        let result = try await run(fixture, ids: ["Photos"], removing: true)
        #expect(result == TransferResult(done: 1, failed: 0))
        #expect(fixture.target.itemIDs.isSuperset(of: ["Photos", "Photos/Sunset.heic", "Photos/Birthday.mp4"]))
        #expect(fixture.source.item("Photos") == nil)
        #expect(fixture.source.item("Photos/Sunset.heic") == nil)
        let removeFolder = try #require(fixture.log.index(of: "src.remove:Photos"))
        let lastAdd = try #require(fixture.log.events.lastIndex { $0.hasPrefix("tgt.addFile:") })
        #expect(lastAdd < removeFolder)
    }

    @Test("A folder whose name clashes is recreated as \"<name> 1\" and its files go inside that one")
    func clashingFolderGetsSuffix() async throws {
        let fixture = TransferFixture()
        _ = try await fixture.target.inner.createFolder(named: "Photos", in: fixture.target.root)
        try await run(fixture, ids: ["Photos"], removing: false)
        #expect(fixture.target.item("Photos 1")?.isDirectory == true)
        #expect(fixture.target.item("Photos 1/Sunset.heic") != nil)
        #expect(fixture.target.item("Photos 1/Birthday.mp4") != nil)
        #expect(fixture.target.item("Photos/Sunset.heic") == nil)
    }

    @Test("Nested folders are recreated with their files")
    func nestedFolders() async throws {
        let fixture = TransferFixture()
        let photos = try #require(fixture.source.item("Photos")?.asDirectory)
        let deep = try await fixture.source.inner.createFolder(named: "Deep", in: photos)
        let deepDirectory = try #require(deep.asDirectory)
        _ = try await fixture.source.inner.addFile(
            from: URL(fileURLWithPath: "/dev/null"), named: "Nested.txt", to: deepDirectory)
        let result = try await run(fixture, ids: ["Photos"], removing: true)
        #expect(result == TransferResult(done: 1, failed: 0))
        #expect(fixture.target.item("Photos/Deep/Nested.txt") != nil)
        #expect(fixture.source.item("Photos") == nil)
    }

    @Test("An empty folder is recreated in the target and counts as one item done")
    func emptyFolder() async throws {
        let fixture = TransferFixture()
        let result = try await run(fixture, ids: ["Documents"], removing: true)
        #expect(result == TransferResult(done: 1, failed: 0))
        #expect(fixture.target.item("Documents")?.isDirectory == true)
        #expect(fixture.source.item("Documents") == nil)
    }

    @Test("A moved folder is kept in the source when one file in it failed; copied files stay in both")
    func folderKeptWhenContentFails() async throws {
        let fixture = TransferFixture()
        fixture.source.failOpen(["Photos/Birthday.mp4"])
        let result = try await run(fixture, ids: ["Photos"], removing: true)
        #expect(result == TransferResult(done: 0, failed: 1))
        #expect(fixture.source.item("Photos") != nil)
        #expect(fixture.source.item("Photos/Birthday.mp4") != nil)
        #expect(fixture.source.item("Photos/Sunset.heic") != nil)
        #expect(fixture.target.item("Photos/Sunset.heic") != nil)
        #expect(!fixture.log.events.contains("src.remove:Photos"))
    }

    // MARK: - Failures

    @Test("An item that fails doesn't stop the others, and the result counts top-level items")
    func failureDoesNotStopOthers() async throws {
        let fixture = TransferFixture()
        fixture.source.failOpen(["Beach.jpg"])
        let result = try await run(fixture, ids: ["Beach.jpg", "Holiday.mov", "Photos"], removing: true)
        #expect(result == TransferResult(done: 2, failed: 1))
        #expect(fixture.target.item("Holiday.mov") != nil)
        #expect(fixture.target.item("Photos/Sunset.heic") != nil)
        #expect(fixture.target.item("Beach.jpg") == nil)
    }

    @Test("A failed move keeps the original in the source")
    func failedCopyKeepsOriginal() async throws {
        let fixture = TransferFixture()
        fixture.target.failAddFile(["Beach.jpg"])
        let result = try await run(fixture, ids: ["Beach.jpg", "Holiday.mov"], removing: true)
        #expect(result == TransferResult(done: 1, failed: 1))
        #expect(fixture.source.item("Beach.jpg") != nil)
        #expect(!fixture.log.events.contains("src.remove:Beach.jpg"))
        #expect(fixture.source.item("Holiday.mov") == nil)
    }

    @Test("A folder counts as one failed item, not one per file")
    func folderFailureCountsOnce() async throws {
        let fixture = TransferFixture()
        fixture.source.failOpen(["Photos/Sunset.heic", "Photos/Birthday.mp4"])
        let result = try await run(fixture, ids: ["Photos"], removing: false)
        #expect(result == TransferResult(done: 0, failed: 1))
    }

    @Test("Nothing is removed from the source before its copy exists in the target")
    func nothingRemovedBeforeCopy() async throws {
        let fixture = TransferFixture()
        try await run(fixture, ids: ["Beach.jpg", "Holiday.mov", "Photos", "Notes.rtf"], removing: true)
        for id in ["Beach.jpg", "Holiday.mov", "Notes.rtf"] {
            let add = try #require(fixture.log.index(of: "tgt.addFile:\(id)"))
            let remove = try #require(fixture.log.index(of: "src.remove:\(id)"))
            #expect(add < remove)
        }
    }

    // MARK: - Edge cases

    @Test("A moved file whose original can't be removed counts as failed; the copy stays in the target")
    func removeFailureFailsFileItem() async throws {
        let fixture = TransferFixture()
        fixture.source.failRemove(["Beach.jpg"])
        let result = try await run(fixture, ids: ["Beach.jpg"], removing: true)
        #expect(result == TransferResult(done: 0, failed: 1))
        #expect(fixture.target.item("Beach.jpg") != nil)
        #expect(fixture.source.item("Beach.jpg") != nil)
    }

    @Test("A moved folder whose original can't be removed counts as failed; the copy stays in the target")
    func removeFailureFailsFolderItem() async throws {
        let fixture = TransferFixture()
        fixture.source.failRemove(["Photos"])
        let result = try await run(fixture, ids: ["Photos"], removing: true)
        #expect(result == TransferResult(done: 0, failed: 1))
        #expect(fixture.target.itemIDs.isSuperset(of: ["Photos", "Photos/Sunset.heic", "Photos/Birthday.mp4"]))
        #expect(fixture.source.item("Photos") != nil)
    }

    private func addNestedFile(_ fixture: TransferFixture) async throws {
        let photos = try #require(fixture.source.item("Photos")?.asDirectory)
        let deep = try await fixture.source.inner.createFolder(named: "Deep", in: photos)
        let deepDirectory = try #require(deep.asDirectory)
        _ = try await fixture.source.inner.addFile(
            from: URL(fileURLWithPath: "/dev/null"), named: "Nested.txt", to: deepDirectory)
    }

    @Test("A folder that can't be created fails its whole item: nothing copied or removed, progress reaches the total")
    func createFolderFailureFailsWholeItem() async throws {
        let fixture = TransferFixture()
        try await addNestedFile(fixture)
        fixture.target.failCreateFolder(["Photos"])
        let recorder = TransferProgressRecorder()
        let result = try await run(fixture, ids: ["Photos"], removing: true, progress: recorder.callback)
        #expect(result == TransferResult(done: 0, failed: 1))
        #expect(fixture.log.events.filter { $0.hasPrefix("tgt.addFile:") }.isEmpty)
        #expect(fixture.log.events.filter { $0.hasPrefix("src.remove:") }.isEmpty)
        #expect(fixture.source.itemIDs.isSuperset(of: ["Photos", "Photos/Sunset.heic", "Photos/Deep/Nested.txt"]))
        #expect(recorder.calls.last == [3, 3])
    }

    @Test("A createFolder that returns a non-folder item fails the whole item the same way")
    func createFolderReturningFileFailsWholeItem() async throws {
        let fixture = TransferFixture()
        try await addNestedFile(fixture)
        fixture.target.createFolderReturnsFile(["Photos"])
        let recorder = TransferProgressRecorder()
        let result = try await run(fixture, ids: ["Photos"], removing: true, progress: recorder.callback)
        #expect(result == TransferResult(done: 0, failed: 1))
        #expect(fixture.log.events.filter { $0.hasPrefix("tgt.addFile:") }.isEmpty)
        #expect(fixture.log.events.filter { $0.hasPrefix("src.remove:") }.isEmpty)
        #expect(fixture.source.itemIDs.isSuperset(of: ["Photos", "Photos/Sunset.heic", "Photos/Deep/Nested.txt"]))
        #expect(recorder.calls.last == [3, 3])
    }

    @Test("An empty folder that can't be created fails its item without any progress call")
    func emptyFolderCreateFailure() async throws {
        let fixture = TransferFixture()
        fixture.target.failCreateFolder(["Documents"])
        let recorder = TransferProgressRecorder()
        let result = try await run(fixture, ids: ["Documents"], removing: true, progress: recorder.callback)
        #expect(result == TransferResult(done: 0, failed: 1))
        #expect(recorder.calls.isEmpty)
        #expect(fixture.source.item("Documents") != nil)
    }

    // MARK: - Copy mode

    @Test("Copying never removes anything from the source")
    func copyNeverRemoves() async throws {
        let fixture = TransferFixture()
        try await run(fixture, ids: ["Beach.jpg", "Photos", "Documents"], removing: false)
        #expect(fixture.log.events.filter { $0.hasPrefix("src.remove:") || $0.hasPrefix("src.moveToTrash:") }.isEmpty)
    }

    @Test("Moving removes originals for good, not to Recently Deleted")
    func moveDoesNotUseTrash() async throws {
        let fixture = TransferFixture()
        try await run(fixture, ids: ["Beach.jpg", "Photos"], removing: true)
        #expect(fixture.log.events.filter { $0.contains("moveToTrash") }.isEmpty)
        #expect(try await fixture.source.trashContents().filter { $0.name == "Beach.jpg" }.isEmpty)
    }

    // MARK: - Progress

    @Test("progress(done, total) is reported after each file")
    func progressAfterEachFile() async throws {
        let fixture = TransferFixture()
        let recorder = TransferProgressRecorder()
        try await run(
            fixture, ids: ["Beach.jpg", "Holiday.mov", "Notes.rtf"], removing: false, progress: recorder.callback)
        #expect(recorder.calls == [[1, 3], [2, 3], [3, 3]])
    }

    @Test("The progress total counts the files inside folders")
    func progressCountsFolderFiles() async throws {
        let fixture = TransferFixture()
        let recorder = TransferProgressRecorder()
        try await run(fixture, ids: ["Beach.jpg", "Photos"], removing: true, progress: recorder.callback)
        #expect(recorder.calls == [[1, 3], [2, 3], [3, 3]])
    }

    // MARK: - Temporary copies

    @Test("A decrypted temp copy of an encrypted item is removed after it was added to the target")
    func tempCopyRemoved() async throws {
        let fixture = TransferFixture()
        let plain = try #require(fixture.source.item("Beach.jpg"))
        try await fixture.source.inner.migrateToEncrypted(plain)
        let encrypted = try #require(fixture.source.item("Beach.jpg"))
        #expect(encrypted.isEncrypted)
        try await run(fixture, ids: ["Beach.jpg"], removing: false)
        let add = try #require(fixture.log.index(of: "tgt.addFile:Beach.jpg"))
        let cleanup = try #require(fixture.log.index(of: "src.removeTemporary:\(encrypted.diskURL.path)"))
        #expect(add < cleanup)
    }

    @Test("The temp copy is removed even when adding it to the target fails")
    func tempCopyRemovedOnFailure() async throws {
        let fixture = TransferFixture()
        let plain = try #require(fixture.source.item("Beach.jpg"))
        try await fixture.source.inner.migrateToEncrypted(plain)
        let encrypted = try #require(fixture.source.item("Beach.jpg"))
        fixture.target.failAddFile(["Beach.jpg"])
        let result = try await run(fixture, ids: ["Beach.jpg"], removing: false)
        #expect(result == TransferResult(done: 0, failed: 1))
        #expect(fixture.log.events.contains("src.removeTemporary:\(encrypted.diskURL.path)"))
    }

    @Test("A plaintext item's file is never removed as a temp copy")
    func plaintextOpenIsNotRemoved() async throws {
        let fixture = TransferFixture()
        try await run(fixture, ids: ["Beach.jpg"], removing: false)
        #expect(fixture.log.events.filter { $0.contains("removeTemporary") }.isEmpty)
    }

    // MARK: - Vault kinds

    @Test("Plaintext to plaintext goes through open")
    func plaintextToPlaintext() async throws {
        let fixture = TransferFixture(sourceEncrypted: false, targetEncrypted: false)
        let result = try await run(fixture, ids: ["Beach.jpg"], removing: false)
        #expect(result == TransferResult(done: 1, failed: 0))
        #expect(fixture.log.events.contains("src.open:Beach.jpg"))
        #expect(fixture.target.item("Beach.jpg") != nil)
    }

    @Test("Encrypted to encrypted goes through open")
    func encryptedToEncrypted() async throws {
        let fixture = TransferFixture(sourceEncrypted: true, targetEncrypted: true)
        let result = try await run(fixture, ids: ["Beach.jpg", "Photos"], removing: true)
        #expect(result == TransferResult(done: 2, failed: 0))
        #expect(fixture.log.events.contains("src.open:Beach.jpg"))
        #expect(fixture.log.events.contains("src.open:Photos/Sunset.heic"))
        #expect(fixture.target.item("Photos/Sunset.heic") != nil)
        #expect(fixture.source.item("Beach.jpg") == nil)
    }

    @Test("Encrypted to plaintext and plaintext to encrypted both work")
    func mixedKinds() async throws {
        let toPlain = TransferFixture(sourceEncrypted: true, targetEncrypted: false)
        let first = try await run(toPlain, ids: ["Beach.jpg"], removing: false)
        #expect(first == TransferResult(done: 1, failed: 0))
        #expect(toPlain.log.events.contains("src.open:Beach.jpg"))
        let toEncrypted = TransferFixture(sourceEncrypted: false, targetEncrypted: true)
        let second = try await run(toEncrypted, ids: ["Beach.jpg"], removing: false)
        #expect(second == TransferResult(done: 1, failed: 0))
        #expect(toEncrypted.log.events.contains("src.open:Beach.jpg"))
    }

    // MARK: - Cancellation

    private final class TaskBox: Sendable {
        private let task = OSAllocatedUnfairLock<Task<TransferResult, any Error>?>(initialState: nil)
        var value: Task<TransferResult, any Error>? {
            get { task.withLock { $0 } }
            set { task.withLock { $0 = newValue } }
        }
    }

    @Test("Cancelling stops before the next file and keeps what is done")
    func cancellationStopsBeforeNextFile() async throws {
        let fixture = TransferFixture()
        let items = try ["Beach.jpg", "Holiday.mov", "Notes.rtf"].map { try #require(fixture.source.item($0)) }
        let transfer = makeTransfer(pro: true)
        let box = TaskBox()
        fixture.target.afterAddFile { box.value?.cancel() }
        let source = fixture.source
        let target = fixture.target
        let task = Task<TransferResult, any Error> {
            while box.value == nil { await Task.yield() }
            return try await transfer.transfer(
                items, from: source, to: target, removingOriginals: true, progress: { _, _ in })
        }
        box.value = task
        _ = await task.result
        let adds = fixture.log.events.filter { $0.hasPrefix("tgt.addFile:") }
        #expect(adds == ["tgt.addFile:Beach.jpg"])
        #expect(!fixture.log.events.contains("src.open:Holiday.mov"))
        #expect(fixture.target.item("Beach.jpg") != nil)
        #expect(fixture.source.item("Holiday.mov") != nil)
        #expect(fixture.source.item("Notes.rtf") != nil)
    }
}
