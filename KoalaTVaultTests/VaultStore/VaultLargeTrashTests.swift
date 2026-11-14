import Foundation
import Testing
import os

@testable import KoalaTVault

/// Large-trash speed (feature multiple-vaults-duress-password, device retest 2026-11-13): the trash listing reads
/// stored flags in one pass and never opens a trash file; restore checks only its own file; a missing file on
/// restore or delete just drops the entry.
@Suite struct VaultLargeTrashTests {
    // MARK: - Helpers

    private func trash(
        _ vault: VaultStoreFixture, _ name: String, _ content: String, in directory: VaultDirectory? = nil
    ) async throws -> VaultItem {
        let item = try await vault.add(name, content, to: directory)
        try await vault.store.moveToTrash(item)
        let all = try await vault.store.trashContents()
        return try #require(all.first { $0.name == name })
    }

    private func entryName(_ item: VaultItem) -> String { (item.id as NSString).lastPathComponent }

    private func isStrictRead(_ call: MockFileCipher.Call) -> Bool {
        switch call {
        case .streamInfo, .decryptChunk, .decryptFile, .encryptFile: true
        case .encrypt, .decrypt: false
        }
    }

    // MARK: - trashContents never reads a trash file

    @Test(
        "trashContents never opens, copies or decrypts a trash file",
        arguments: [LockMode.none, .password])
    func listingNeverReadsTrashFiles(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode, headerAware: true, selective: true)
        defer { vault.cleanUp() }
        let docs = try await vault.store.createFolder(named: "Docs", in: vault.root)
        let docsDirectory = try #require(docs.asDirectory)
        try await vault.add("inner.txt", "inner", to: docsDirectory)
        try await vault.store.moveToTrash(docs)
        for index in 0..<3 {
            let item = try await vault.add("file\(index).txt", "content \(index)")
            try await vault.store.moveToTrash(item)
        }
        let failing = try #require(vault.failing)
        let callsBefore = vault.cipher.calls.count
        let infoBefore = failing.streamInfoURLs.count
        let chunksBefore = failing.decryptChunkCalls.count

        let listed = try await vault.store.trashContents()

        #expect(listed.count == 4)
        #expect(failing.streamInfoURLs.count == infoBefore)
        #expect(failing.decryptChunkCalls.count == chunksBefore)
        #expect(!vault.cipher.calls.dropFirst(callsBefore).contains(where: isStrictRead))
        #expect(vault.tempFiles().isEmpty)
        #expect(vault.tempContents().isEmpty)
    }

    @Test("trashContents reports the entry's stored flag even when the file's real form differs")
    func listingUsesStoredFlag() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, headerAware: true)
        defer { vault.cleanUp() }
        let sealedButFlaggedPlain = try await trash(vault, "sealed.txt", "sealed content")
        let plainButFlaggedSealed = try await trash(vault, "plain.txt", "plain content")
        try Data("plain content".utf8).write(to: plainButFlaggedSealed.diskURL)
        let sealedName = entryName(sealedButFlaggedPlain)
        let plainName = entryName(plainButFlaggedSealed)
        try vault.rewriteTrashEntriesByKey { key, entry in
            if key == sealedName { entry["isEncrypted"] = false }
            if key == plainName { entry["isEncrypted"] = true }
        }

        let listed = try await vault.store.trashContents()

        #expect(listed.first { $0.name == "sealed.txt" }?.isEncrypted == false)
        #expect(listed.first { $0.name == "plain.txt" }?.isEncrypted == true)
        #expect(vault.isSealedOnDisk(sealedButFlaggedPlain.diskURL))
        #expect(!vault.isSealedOnDisk(plainButFlaggedSealed.diskURL))
    }

    @Test("trashContents in a plaintext vault reports a stored encrypted flag for a plaintext file")
    func listingUsesStoredFlagInPlaintextVault() async throws {
        let vault = try VaultStoreFixture(lockMode: .none, headerAware: true)
        defer { vault.cleanUp() }
        _ = try await trash(vault, "note.txt", "note")
        try vault.rewriteTrashEntries { $0["isEncrypted"] = true }

        let listed = try await vault.store.trashContents()

        #expect(listed.map(\.name) == ["note.txt"])
        #expect(listed.first?.isEncrypted == true)
    }

    @Test("trashContents doesn't list an entry whose file is missing and lists the others unchanged")
    func listingSkipsMissingFileKeepsOthers() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, headerAware: true)
        defer { vault.cleanUp() }
        let lost = try await trash(vault, "lost.txt", "lost")
        _ = try await trash(vault, "kept.txt", "kept")
        try FileManager.default.removeItem(at: lost.diskURL)

        let listed = try await vault.store.trashContents()

        #expect(listed.map(\.name) == ["kept.txt"])
        #expect(listed.first?.isEncrypted == true)
    }

    @Test(
        "trashContents gives each item's name, size, date, folder flag, deletedAt, id and location",
        arguments: [LockMode.none, .password])
    func listingFields(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        let report = try await vault.add("report.pdf", "twelve bytes", to: docs)
        let folder = try await vault.store.createFolder(named: "Sub", in: vault.root)
        let folderDirectory = try #require(folder.asDirectory)
        try await vault.add("inner.txt", "inner", to: folderDirectory)
        let before = Date()
        try await vault.store.moveToTrash(report)
        try await vault.store.moveToTrash(folder)
        let stamp = Date(timeIntervalSince1970: 1_500_000_000)
        let trashedReport = try #require(try await vault.store.trashContents().first { $0.name == "report.pdf" })
        try vault.setModified(trashedReport.diskURL, to: stamp)

        let listed = try await vault.store.trashContents()

        #expect(listed.count == 2)
        let file = try #require(listed.first { $0.name == "report.pdf" })
        let size = (try FileManager.default.attributesOfItem(atPath: file.diskURL.path)[.size] as? NSNumber)?.intValue
        #expect(file.fileSize == size)
        #expect(abs(file.dateModified.timeIntervalSince(stamp)) < 1)
        #expect(file.isDirectory == false)
        #expect(file.kind == .pdf)
        #expect(file.id == ".trash/" + file.diskURL.lastPathComponent)
        #expect(file.diskURL.deletingLastPathComponent().standardizedFileURL == vault.trashURL.standardizedFileURL)
        #expect(file.rootURL == vault.rootURL)
        #expect(file.isEncrypted == (mode != .none))
        #expect(abs(try #require(file.deletedAt).timeIntervalSince(before)) < 60)
        let sub = try #require(listed.first { $0.name == "Sub" })
        #expect(sub.isDirectory)
        #expect(sub.isEncrypted == false)
        #expect(sub.id == ".trash/" + sub.diskURL.lastPathComponent)
        #expect(abs(try #require(sub.deletedAt).timeIntervalSince(before)) < 60)
        #expect(try await vault.store.trashContents().map(\.id) == listed.map(\.id))
    }

    // MARK: - restore checks only its own file

    @Test("restore probes only the restored item's own file, never the other trash files")
    func restoreProbesOnlyOwnFile() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, headerAware: true, selective: true)
        defer { vault.cleanUp() }
        let failing = try #require(vault.failing)
        _ = try await trash(vault, "other1.txt", "marker-other-one")
        let target = try await trash(vault, "target.txt", "marker-target")
        _ = try await trash(vault, "other2.txt", "marker-other-two")
        let seen = OSAllocatedUnfairLock<[String]>(initialState: [])
        @Sendable func record(_ url: URL) {
            failing.onFirstStreamInfo = record
            if let data = try? Data(contentsOf: url) {
                seen.withLock { $0.append(String(decoding: data, as: UTF8.self)) }
            }
        }
        failing.onFirstStreamInfo = record
        let chunkSeen = OSAllocatedUnfairLock<[String]>(initialState: [])
        failing.decryptChunkErrorFor = { url in
            if let data = try? Data(contentsOf: url) {
                chunkSeen.withLock { $0.append(String(decoding: data, as: UTF8.self)) }
            }
            return nil
        }

        let restored = try await vault.store.restore(target)

        #expect(try await vault.openedContent(restored) == "marker-target")
        for text in seen.withLock({ $0 }) + chunkSeen.withLock({ $0 }) {
            #expect(!text.contains("marker-other"))
        }
        #expect(try await vault.store.trashContents().map(\.name).sorted() == ["other1.txt", "other2.txt"])
    }

    struct RealFormCase: Sendable, CustomTestStringConvertible {
        let label: String
        let lockMode: LockMode
        /// The flag the entry stores.
        let storedEncrypted: Bool
        /// Whether the trash file really is in SVC5 form.
        let fileSealed: Bool

        var testDescription: String { label }

        static let all: [RealFormCase] = [
            RealFormCase(
                label: "stored plaintext, file sealed", lockMode: .password, storedEncrypted: false, fileSealed: true),
            RealFormCase(
                label: "stored encrypted, file plaintext", lockMode: .password, storedEncrypted: true,
                fileSealed: false),
            RealFormCase(
                label: "stored encrypted, file plaintext, plaintext vault", lockMode: .none, storedEncrypted: true,
                fileSealed: false),
        ]
    }

    @Test("restore still corrects the item's real form when its stored flag is wrong", arguments: RealFormCase.all)
    func restoreCorrectsRealForm(scenario: RealFormCase) async throws {
        let vault = try VaultStoreFixture(lockMode: scenario.lockMode, headerAware: true)
        defer { vault.cleanUp() }
        let trashed = try await trash(vault, "doc.txt", "real content")
        let bytes = Data("real content".utf8)
        try (scenario.fileSealed ? HeaderAwareTestCipher.sealed(bytes) : bytes).write(to: trashed.diskURL)
        try vault.rewriteTrashEntries { $0["isEncrypted"] = scenario.storedEncrypted }
        let listed = try #require(try await vault.store.trashContents().first)

        let restored = try await vault.store.restore(listed)

        #expect(restored.name == "doc.txt")
        #expect(try await vault.openedContent(restored) == "real content")
        #expect(try await vault.names() == ["doc.txt"])
        #expect(try await vault.store.trashContents().isEmpty)
        #expect(vault.trashEntries()?.isEmpty ?? true)
    }

    @Test(
        "restore of an entry whose file is gone drops the entry and throws notFound",
        arguments: [LockMode.none, .password])
    func restoreMissingFileDropsEntry(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        let lost = try await trash(vault, "lost.txt", "lost", in: docs)
        let kept = try await trash(vault, "kept.txt", "kept", in: docs)
        try FileManager.default.removeItem(at: lost.diskURL)

        let error = await caught { _ = try await vault.store.restore(lost) }

        #expect(error as? VaultStoreError == .notFound)
        let entries = try #require(vault.trashEntries())
        #expect(entries.count == 1)
        #expect(entries[entryName(kept)] != nil)
        #expect(entries[entryName(lost)] == nil)
        #expect(try await vault.names(docs).isEmpty)
        #expect(try await vault.store.trashContents().map(\.id) == [kept.id])
        let restored = try await vault.store.restore(kept)
        #expect(try await vault.openedContent(restored) == "kept")
    }

    @Test("restore of the only entry when its file is gone leaves an empty trash index")
    func restoreMissingOnlyEntry() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let lost = try await trash(vault, "lost.txt", "lost")
        try FileManager.default.removeItem(at: lost.diskURL)

        let error = await caught { _ = try await vault.store.restore(lost) }

        #expect(error as? VaultStoreError == .notFound)
        #expect(vault.trashEntries()?.isEmpty ?? true)
        #expect(try await vault.names().isEmpty)
    }

    // MARK: - deletePermanently

    @Test(
        "deletePermanently of an entry whose file is gone drops the entry without an error",
        arguments: [LockMode.none, .password])
    func deleteMissingFileDropsEntry(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let lost = try await trash(vault, "lost.txt", "lost")
        let kept = try await trash(vault, "kept.txt", "kept")
        try FileManager.default.removeItem(at: lost.diskURL)

        let error = await caught { try await vault.store.deletePermanently(lost) }

        #expect(error == nil)
        let entries = try #require(vault.trashEntries())
        #expect(entries.count == 1)
        #expect(entries[entryName(kept)] != nil)
        #expect(try await vault.store.trashContents().map(\.id) == [kept.id])
        #expect(FileManager.default.fileExists(atPath: kept.diskURL.path))
    }

    @Test("deletePermanently of an item not in the trash index throws notFound and leaves a file with that name alone")
    func deleteNotInIndexIsNotFound() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        _ = try await trash(vault, "kept.txt", "kept")
        let stray = vault.ghostTrashItem()
        try Data("stray".utf8).write(to: stray.diskURL)
        let before = try vault.snapshot()

        let error = await caught { try await vault.store.deletePermanently(stray) }

        #expect(error as? VaultStoreError == .notFound)
        #expect(try vault.snapshot() == before)
    }
}

extension VaultStoreFixture {
    /// Rewrites every trash entry through `transform`, which also gets the entry's key (the trash UUID).
    func rewriteTrashEntriesByKey(_ transform: (String, inout [String: Any]) -> Void) throws {
        guard let data = rawTrashMap(), var entries = trashEntries() else { return }
        for key in entries.keys {
            var entry = entries[key] ?? [:]
            transform(key, &entry)
            entries[key] = entry
        }
        let json = try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys])
        var prefix = Data()
        if data.starts(with: Self.sealedPrefix) {
            let rest = data.dropFirst(Self.sealedPrefix.count)
            if let colon = rest.firstIndex(of: UInt8(ascii: ":")) { prefix = Data(data.prefix(upTo: colon + 1)) }
        }
        try (prefix + json).write(to: trashMapURL)
    }
}
