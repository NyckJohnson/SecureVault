import Foundation
import Testing

@testable import KoalaTVault

@MainActor
@Suite struct LiveVaultImporterBatchTests {
    private typealias Fixture = ImporterTestFixture

    /// Records progress values together with how many files had been handed to `addFiles` at that moment.
    private final class ProgressWithAdded: @unchecked Sendable {
        private let store: DiskBackedVaultStore
        private let lock = NSLock()
        private var _values: [Double] = []
        private var _addedAtReport: [Int] = []
        init(store: DiskBackedVaultStore) { self.store = store }
        var values: [Double] { lock.withLock { _values } }
        var addedAtReport: [Int] { lock.withLock { _addedAtReport } }
        func record(_ value: Double) {
            let added = store.addedNames.count
            lock.withLock {
                _values.append(value)
                _addedAtReport.append(added)
            }
        }
    }

    private func names(_ range: ClosedRange<Int>) -> [String] {
        range.map { "f" + String(format: "%03d", $0) + ".txt" }
    }

    @Test("150 loose files go to addFiles in batches of 64, 64 and 22, in the order picked")
    func looseFilesBatchedBy64InOrder() async throws {
        let fixture = try Fixture(isPro: true)
        defer { fixture.cleanup() }
        let all = names(1...150)
        let urls = try all.map { try fixture.source.file($0, content: "c-\($0)") }
        let result = try await fixture.importItems(urls)
        #expect(result == ImportResult(imported: 150, skippedDuplicates: 0, failed: 0))
        #expect(fixture.store.addFilesCalls.map(\.count) == [64, 64, 22])
        #expect(fixture.store.addFilesCalls == [Array(all[0..<64]), Array(all[64..<128]), Array(all[128..<150])])
        #expect(fixture.store.addCalls.isEmpty)
        #expect(fixture.store.readString("f150.txt") == "c-f150.txt")
    }

    @Test("A batch never holds more than 64 files, whatever the count", arguments: [1, 63, 64, 65, 128, 129])
    func batchSizeNeverExceeds64(count: Int) async throws {
        let fixture = try Fixture(isPro: true)
        defer { fixture.cleanup() }
        let urls = try names(1...count).map { try fixture.source.file($0, content: $0) }
        let result = try await fixture.importItems(urls)
        #expect(result.imported == count)
        let sizes = fixture.store.addFilesCalls.map(\.count)
        #expect(sizes.allSatisfy { (1...64).contains($0) })
        #expect(sizes.reduce(0, +) == count)
        #expect(sizes.count == (count + 63) / 64)
        #expect(sizes.dropLast().allSatisfy { $0 == 64 })
    }

    @Test("150 files in one picked folder go to that folder in batches of 64, 64 and 22")
    func folderFilesBatchedBy64() async throws {
        let fixture = try Fixture(isPro: true)
        defer { fixture.cleanup() }
        let all = names(1...150)
        for name in all { try fixture.source.file("Trip/" + name, content: name) }
        let result = try await fixture.importItems([fixture.source.url.appendingPathComponent("Trip")])
        #expect(result == ImportResult(imported: 150, skippedDuplicates: 0, failed: 0))
        #expect(fixture.store.batches(in: "Trip").map(\.count) == [64, 64, 22])
        #expect(Set(fixture.store.addedNames(in: "Trip")) == Set(all))
        #expect(fixture.store.addedNames.count == 150)
        #expect(fixture.store.allPaths().contains("Trip/f150.txt"))
    }

    @Test("Loose files and the files of each picked folder and subfolder go to their own destination's batches")
    func eachDestinationGetsItsOwnBatches() async throws {
        let fixture = try Fixture(isPro: true)
        defer { fixture.cleanup() }
        let loose1 = try fixture.source.file("a.txt", content: "A")
        let loose2 = try fixture.source.file("b.txt", content: "B")
        try fixture.source.file("Trip/t1.txt", content: "1")
        try fixture.source.file("Trip/t2.txt", content: "2")
        try fixture.source.file("Trip/t3.txt", content: "3")
        try fixture.source.file("Trip/Sub/s1.txt", content: "s1")
        try fixture.source.file("Trip/Sub/s2.txt", content: "s2")
        let trip = fixture.source.url.appendingPathComponent("Trip")
        let result = try await fixture.importItems([loose1, trip, loose2])
        #expect(result == ImportResult(imported: 7, skippedDuplicates: 0, failed: 0))
        #expect(fixture.store.addedNames(in: "") == ["a.txt", "b.txt"])
        #expect(Set(fixture.store.addedNames(in: "Trip")) == ["t1.txt", "t2.txt", "t3.txt"])
        #expect(Set(fixture.store.addedNames(in: "Trip/Sub")) == ["s1.txt", "s2.txt"])
        #expect(fixture.store.addedNames.count == 7)
        #expect(fixture.store.addFilesBatches.allSatisfy { !$0.names.isEmpty && $0.names.count <= 64 })
    }

    @Test("A file whose name is not in the destination needs no findItem lookup")
    func newNamesAreNotLookedUp() async throws {
        let fixture = try Fixture(isPro: true)
        defer { fixture.cleanup() }
        try fixture.store.seed("other.txt", content: "other")
        let urls = try names(1...70).map { try fixture.source.file($0, content: $0) }
        try fixture.source.file("Trip/x.txt", content: "x")
        let result = try await fixture.importItems(urls + [fixture.source.url.appendingPathComponent("Trip")])
        #expect(result == ImportResult(imported: 71, skippedDuplicates: 0, failed: 0))
        #expect(fixture.store.findItemNames.isEmpty)
    }

    @Test("Only names already in the destination go through findItem, and only those are hash-checked")
    func onlyExistingNamesAreLookedUp() async throws {
        let fixture = try Fixture(isPro: true)
        defer { fixture.cleanup() }
        try fixture.store.seed("dup.txt", content: "same")
        try fixture.store.seed("diff.txt", content: "old")
        let dup = try fixture.source.file("dup.txt", content: "same")
        let diff = try fixture.source.file("diff.txt", content: "new")
        let fresh = try fixture.source.file("fresh.txt", content: "fresh")
        let result = try await fixture.importItems([dup, fresh, diff])
        #expect(result == ImportResult(imported: 2, skippedDuplicates: 1, failed: 0))
        #expect(fixture.store.findItemNames.sorted() == ["diff.txt", "dup.txt"])
        #expect(fixture.store.addedNames == ["fresh.txt", "diff.txt"])
        #expect(fixture.store.readString("diff 1.txt") == "new")
        #expect(fixture.store.readString("fresh.txt") == "fresh")
    }

    @Test("In an encrypted vault only the name already there is looked up and hash-checked")
    func encryptedOnlyExistingNamesAreLookedUp() async throws {
        let fixture = try Fixture(isPro: true, encrypted: true)
        defer { fixture.cleanup() }
        try fixture.store.seed("dup.txt", content: "same")
        let dup = try fixture.source.file("dup.txt", content: "same")
        let fresh = try fixture.source.file("fresh.txt", content: "fresh")
        let result = try await fixture.importItems([dup, fresh])
        #expect(result == ImportResult(imported: 1, skippedDuplicates: 1, failed: 0))
        #expect(fixture.store.findItemNames == ["dup.txt"])
        #expect(fixture.store.leftoverTempFiles.isEmpty)
    }

    @Test("A name added earlier by this import goes through the hash check: same content is skipped")
    func nameAddedByThisImportSameContentIsSkipped() async throws {
        let fixture = try Fixture(isPro: true)
        defer { fixture.cleanup() }
        let first = try fixture.source.file("one/a.txt", content: "same")
        let second = try fixture.source.file("two/a.txt", content: "same")
        let result = try await fixture.importItems([first, second])
        #expect(result == ImportResult(imported: 1, skippedDuplicates: 1, failed: 0))
        #expect(fixture.store.allPaths() == ["a.txt"])
        #expect(fixture.store.findItemNames == ["a.txt"])
    }

    @Test("A name added earlier by this import goes through the hash check: other content gets ' 1'")
    func nameAddedByThisImportDifferentContentGetsSuffix() async throws {
        let fixture = try Fixture(isPro: true)
        defer { fixture.cleanup() }
        let first = try fixture.source.file("one/a.txt", content: "first")
        let second = try fixture.source.file("two/a.txt", content: "second")
        let result = try await fixture.importItems([first, second])
        #expect(result == ImportResult(imported: 2, skippedDuplicates: 0, failed: 0))
        #expect(fixture.store.readString("a.txt") == "first")
        #expect(fixture.store.readString("a 1.txt") == "second")
        #expect(fixture.store.findItemNames == ["a.txt"])
    }

    @Test("Duplicates among many files are skipped and counted, and only the rest are batched in order")
    func duplicatesInsideLargeImportAreSkipped() async throws {
        let fixture = try Fixture(isPro: true)
        defer { fixture.cleanup() }
        let all = names(1...100)
        for name in all[0..<4] { try fixture.store.seed(name, content: "c-" + name) }
        try fixture.store.seed(all[4], content: "old")
        let urls = try all.map { try fixture.source.file($0, content: "c-" + $0) }
        let result = try await fixture.importItems(urls)
        #expect(result == ImportResult(imported: 96, skippedDuplicates: 4, failed: 0))
        #expect(fixture.store.addedNames == Array(all[4...]))
        #expect(fixture.store.addFilesCalls.map(\.count) == [64, 32])
        #expect(fixture.store.readString("f005.txt") == "old")
        #expect(fixture.store.readString("f005 1.txt") == "c-f005.txt")
        #expect(fixture.store.findItemNames.sorted() == Array(all[0...4]))
    }

    @Test("The destination folder is listed once for the whole import, however many batches it takes")
    func destinationListedOnce() async throws {
        let fixture = try Fixture(isPro: true)
        defer { fixture.cleanup() }
        try fixture.store.seed("existing.txt", content: "e")
        let urls = try names(1...150).map { try fixture.source.file($0, content: $0) }
        _ = try await fixture.importItems(urls)
        #expect(fixture.store.addFilesCalls.count == 3)
        #expect(fixture.store.contentsPaths.filter { $0.isEmpty }.count == 1)
    }

    @Test("Each destination folder is listed at most once, and a merged existing folder exactly once")
    func eachFolderListedOnce() async throws {
        let fixture = try Fixture(isPro: true)
        defer { fixture.cleanup() }
        try fixture.store.seed("Trip/old.txt", content: "old")
        let loose = try fixture.source.file("a.txt", content: "A")
        for name in names(1...70) { try fixture.source.file("Trip/" + name, content: name) }
        try fixture.source.file("Trip/Sub/s.txt", content: "s")
        let result = try await fixture.importItems([loose, fixture.source.url.appendingPathComponent("Trip")])
        #expect(result == ImportResult(imported: 72, skippedDuplicates: 0, failed: 0))
        let paths = fixture.store.contentsPaths
        #expect(paths.filter { $0.isEmpty }.count == 1)
        #expect(paths.filter { $0 == "Trip" }.count == 1)
        #expect(paths.filter { $0 == "Trip/Sub" }.count <= 1)
        #expect(fixture.store.batches(in: "Trip").map(\.count) == [64, 6])
    }

    @Test("Progress is reported after each batch, never mid-batch, from 0 to 1 without going backwards")
    func progressAfterEachBatch() async throws {
        let fixture = try Fixture(isPro: true)
        defer { fixture.cleanup() }
        let urls = try names(1...150).map { try fixture.source.file($0, content: $0) }
        let recorder = ProgressWithAdded(store: fixture.store)
        _ = try await fixture.importer.importItems(urls, into: fixture.store.root, progress: { recorder.record($0) })
        let values = recorder.values
        #expect(values.first == 0)
        #expect(values.last == 1)
        #expect(values.allSatisfy { (0...1).contains($0) })
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(values.filter { $0 > 0 && $0 < 1 }.count >= 2)
        #expect(Set(recorder.addedAtReport).isSubset(of: [0, 64, 128, 150]))
        #expect(recorder.addedAtReport.contains(64))
        #expect(recorder.addedAtReport.contains(128))
        #expect(recorder.addedAtReport.last == 150)
    }

    @Test("Each skipped duplicate reports progress, ending at 1")
    func progressAfterEachSkippedDuplicate() async throws {
        let fixture = try Fixture(isPro: true)
        defer { fixture.cleanup() }
        let all = names(1...4)
        for name in all { try fixture.store.seed(name, content: name) }
        let urls = try all.map { try fixture.source.file($0, content: $0) }
        let progress = ProgressRecorder()
        let result = try await fixture.importItems(urls, progress: progress)
        #expect(result == ImportResult(imported: 0, skippedDuplicates: 4, failed: 0))
        #expect(fixture.store.addFilesCalls.isEmpty)
        let values = progress.recorded
        #expect(values.first == 0)
        #expect(values.last == 1)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(Set(values.filter { $0 > 0 }).count >= 4)
    }

    @Test("A batch failure keeps the earlier batches and the failing batch's files before it, and rethrows")
    func batchFailureKeepsEarlierFiles() async throws {
        let fixture = try Fixture(isPro: true)
        defer { fixture.cleanup() }
        let all = names(1...150)
        let urls = try all.map { try fixture.source.file($0, content: $0) }
        fixture.store.failAdding("f070.txt")
        await #expect(throws: VaultStoreError.io("boom")) {
            _ = try await fixture.importItems(urls)
        }
        for name in all[0..<69] { #expect(fixture.store.readString(name) == name) }
        for name in all[69...] { #expect(fixture.store.readString(name) == nil) }
        #expect(fixture.store.addFilesCalls.count == 2)
    }

    @Test("A failure in a later folder keeps the files already added to earlier destinations and rethrows")
    func failureInLaterFolderKeepsEarlierFolders() async throws {
        let fixture = try Fixture(isPro: true)
        defer { fixture.cleanup() }
        let loose = try fixture.source.file("a.txt", content: "A")
        try fixture.source.file("Trip/bad.txt", content: "B")
        fixture.store.failAdding("bad.txt")
        await #expect(throws: VaultStoreError.io("boom")) {
            _ = try await fixture.importItems([loose, fixture.source.url.appendingPathComponent("Trip")])
        }
        #expect(fixture.store.readString("a.txt") == "A")
        #expect(fixture.store.readString("Trip/bad.txt") == nil)
    }

    @Test("A large mixed import reports the right counts: imported, skipped duplicates and failed")
    func countsOfALargeMixedImport() async throws {
        let fixture = try Fixture(isPro: true)
        defer { fixture.cleanup() }
        let all = names(1...80)
        for name in all[0..<5] { try fixture.store.seed(name, content: name) }
        var urls = try all.map { try fixture.source.file($0, content: $0) }
        urls.append(try fixture.source.file("...", content: "dots"))
        let result = try await fixture.importItems(urls)
        #expect(result == ImportResult(imported: 75, skippedDuplicates: 5, failed: 1))
        #expect(fixture.store.addedNames == Array(all[5...]))
        #expect(fixture.store.addFilesCalls.map(\.count) == [64, 11])
    }
}
