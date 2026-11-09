import Foundation
import Testing

@testable import KoalaTVault

/// Edge and failure cases of the unreadable-trash detection and clearing, and of the trash header reads that
/// listing, restore and the migration steps share: anything uncertain is never judged unreadable.
@Suite struct VaultUnreadableTrashFailureTests {
    // MARK: - Helpers

    private func makeVault(_ mode: LockMode = .password, selective: Bool = false) throws -> VaultStoreFixture {
        try VaultStoreFixture(lockMode: mode, headerAware: true, selective: selective)
    }

    @discardableResult
    private func trashFile(
        _ vault: VaultStoreFixture, _ name: String, _ content: String = "data"
    ) async throws -> VaultItem {
        let item = try await vault.add(name, content)
        try await vault.store.moveToTrash(item)
        let all = try await vault.store.trashContents()
        return try #require(all.first { $0.name == name })
    }

    private func trashFolder(_ vault: VaultStoreFixture, _ name: String, file: String) async throws -> VaultItem {
        let folder = try await vault.store.createFolder(named: name, in: vault.root)
        let directory = try #require(folder.asDirectory)
        try await vault.add(file, "inner", to: directory)
        try await vault.store.moveToTrash(folder)
        let all = try await vault.store.trashContents()
        return try #require(all.first { $0.name == name })
    }

    private static let foreignIndex = Data("foreign-sealed:.vault_map:{}".utf8)
    private static let foreignTrashIndex = Data("foreign-sealed:.trash_map:{}".utf8)

    private func sealWithOtherKey(_ url: URL) throws {
        try HeaderAwareTestCipher.sealed(Data("zz".utf8), declaredSize: 4096).write(to: url)
    }

    private func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    /// Every regular, non-hidden file under `folder`, deepest first.
    private func filesUnder(_ folder: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        var urls: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            if isFile && !url.lastPathComponent.hasPrefix(".") { urls.append(url) }
        }
        return urls.sorted { $0.pathComponents.count > $1.pathComponents.count }
    }

    /// Files of the vault only (the temp folder is not vault state).
    private func vaultState(_ vault: VaultStoreFixture) throws -> [String: Data] {
        try vault.snapshot().filter { $0.key.hasPrefix(vault.rootURL.path) }
    }

    /// A trashed `Docs/Sub/Deep` tree: files at every level, each folder with its own index.
    private struct Nested {
        let folder: VaultItem
        let sub: VaultDirectory
        let deep: VaultDirectory
        let deepFile: URL
    }

    private func trashNested(_ vault: VaultStoreFixture) async throws -> Nested {
        let docsItem = try await vault.store.createFolder(named: "Docs", in: vault.root)
        let docs = try #require(docsItem.asDirectory)
        try await vault.add("top.txt", "top", to: docs)
        let subItem = try await vault.store.createFolder(named: "Sub", in: docs)
        let sub = try #require(subItem.asDirectory)
        try await vault.add("sub.txt", "sub", to: sub)
        let deepItem = try await vault.store.createFolder(named: "Deep", in: sub)
        let deep = try #require(deepItem.asDirectory)
        try await vault.add("deep.txt", "deep", to: deep)
        try await vault.store.moveToTrash(docsItem)
        let trashed = try #require(try await vault.store.trashContents().first { $0.name == "Docs" })
        let deepFile = try #require(filesUnder(trashed.diskURL).first)
        let deepDirectory = deepFile.deletingLastPathComponent()
        let subDirectory = deepDirectory.deletingLastPathComponent()
        return Nested(
            folder: trashed,
            sub: VaultDirectory(name: "Sub", diskURL: subDirectory, rootURL: vault.rootURL),
            deep: VaultDirectory(name: "Deep", diskURL: deepDirectory, rootURL: vault.rootURL),
            deepFile: deepFile)
    }

    /// Holds restore closures created inside a `@Sendable` hook.
    private final class RestoreBox: @unchecked Sendable {
        private let lock = NSLock()
        private var actions: [() -> Void] = []
        private(set) var fired = false

        func add(_ action: @escaping () -> Void) {
            lock.lock()
            defer { lock.unlock() }
            actions.append(action)
            fired = true
        }

        func restoreAll() {
            lock.lock()
            let all = actions
            actions = []
            lock.unlock()
            all.forEach { $0() }
        }
    }

    // MARK: - 1. Trash index that is not a trash map

    @Test("A trash index that opens with the key but is not a trash map is uncertain and clearing changes nothing")
    func undecodableTrashIndexIsUncertain() async throws {
        let vault = try makeVault()
        defer { vault.cleanUp() }
        let bad = try await trashFile(vault, "bad.txt")
        try await trashFile(vault, "good.txt")
        try sealWithOtherKey(bad.diskURL)
        let json = Data(#"["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]"#.utf8)
        let index = Data("mock-sealed:.trash_map:".utf8) + json
        try vault.writeRawTrashMap(index)
        let before = try vault.snapshot()

        #expect(await vault.store.hasUnreadableTrash() == false)
        try await vault.store.clearUnreadableTrash()

        #expect(try vault.snapshot() == before)
        #expect(try Data(contentsOf: vault.trashMapURL) == index)
    }

    // MARK: - 2. Symlinked trash item

    @Test("A trash item that is a symlink to a foreign-sealed file is never judged unreadable or cleared")
    func symlinkItemAloneIsNeverJudged() async throws {
        let vault = try makeVault()
        defer { vault.cleanUp() }
        let item = try await trashFile(vault, "a.txt")
        let target = try vault.outsideFolder().appendingPathComponent("target.bin")
        try HeaderAwareTestCipher.sealed(Data("zz".utf8), declaredSize: 4096).write(to: target)
        let targetBytes = try Data(contentsOf: target)
        try FileManager.default.removeItem(at: item.diskURL)
        try FileManager.default.createSymbolicLink(at: item.diskURL, withDestinationURL: target)

        #expect(await vault.store.hasUnreadableTrash() == false)
        try await vault.store.clearUnreadableTrash()

        #expect(isSymlink(item.diskURL))
        #expect(try Data(contentsOf: target) == targetBytes)
        #expect(vault.trashEntries()?.count == 1)
    }

    @Test("A symlink trash item next to a foreign file is kept while the foreign file is cleared")
    func symlinkItemNextToForeignFileIsKept() async throws {
        let vault = try makeVault()
        defer { vault.cleanUp() }
        let linked = try await trashFile(vault, "linked.txt")
        let bad = try await trashFile(vault, "bad.txt")
        let target = try vault.outsideFolder().appendingPathComponent("target.bin")
        try HeaderAwareTestCipher.sealed(Data("zz".utf8), declaredSize: 4096).write(to: target)
        let targetBytes = try Data(contentsOf: target)
        try FileManager.default.removeItem(at: linked.diskURL)
        try FileManager.default.createSymbolicLink(at: linked.diskURL, withDestinationURL: target)
        try sealWithOtherKey(bad.diskURL)

        #expect(await vault.store.hasUnreadableTrash())
        try await vault.store.clearUnreadableTrash()

        #expect(!fileExists(bad.diskURL))
        #expect(isSymlink(linked.diskURL))
        #expect(try Data(contentsOf: target) == targetBytes)
        #expect(vault.trashEntries()?.count == 1)
        #expect(await vault.store.hasUnreadableTrash() == false)
    }

    // MARK: - 3. Unreadable subfolder

    @Test("A trashed folder with an unreadable subfolder and a foreign index is kept whole")
    func unreadableSubfolderKeepsFolderWhole() async throws {
        let vault = try makeVault()
        defer { vault.cleanUp() }
        let folder = try await trashFolder(vault, "Docs", file: "in.txt")
        let sub = folder.diskURL.appendingPathComponent("Locked", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: sub.appendingPathComponent("hidden.txt"))
        try Self.foreignIndex.write(to: folder.diskURL.appendingPathComponent(".vault_map"))
        let restore = try restrict(sub, to: 0o000)
        defer { restore() }

        #expect(await vault.store.hasUnreadableTrash() == false)
        try await vault.store.clearUnreadableTrash()

        restore()
        #expect(fileExists(folder.diskURL))
        #expect(fileExists(sub.appendingPathComponent("hidden.txt")))
        #expect(vault.trashEntries()?.count == 1)
    }

    // MARK: - 4. Nested trees

    @Test("A foreign SVC5 file two levels deep makes the whole trashed folder unreadable and it is cleared")
    func deepForeignFileClearsFolder() async throws {
        let vault = try makeVault()
        defer { vault.cleanUp() }
        let nested = try await trashNested(vault)
        let good = try await trashFile(vault, "good.txt")
        try sealWithOtherKey(nested.deepFile)

        #expect(await vault.store.hasUnreadableTrash())
        try await vault.store.clearUnreadableTrash()

        #expect(!fileExists(nested.folder.diskURL))
        #expect(fileExists(good.diskURL))
        #expect(try await vault.store.trashContents().map(\.name) == ["good.txt"])
        #expect(await vault.store.hasUnreadableTrash() == false)
    }

    @Test("A foreign .vault_map two levels deep makes the whole trashed folder unreadable and it is cleared")
    func deepForeignIndexClearsFolder() async throws {
        let vault = try makeVault()
        defer { vault.cleanUp() }
        let nested = try await trashNested(vault)
        let good = try await trashFile(vault, "good.txt")
        try Self.foreignIndex.write(to: nested.deep.diskURL.appendingPathComponent(".vault_map"))

        #expect(await vault.store.hasUnreadableTrash())
        try await vault.store.clearUnreadableTrash()

        #expect(!fileExists(nested.folder.diskURL))
        #expect(fileExists(good.diskURL))
        #expect(await vault.store.hasUnreadableTrash() == false)
    }

    @Test("A readable nested tree is not unreadable and is not cleared")
    func readableNestedTreeIsKept() async throws {
        let vault = try makeVault()
        defer { vault.cleanUp() }
        _ = try await trashNested(vault)
        let before = try vault.snapshot()

        #expect(await vault.store.hasUnreadableTrash() == false)
        try await vault.store.clearUnreadableTrash()

        #expect(try vault.snapshot() == before)
    }

    @Test("A foreign file deep in a folder that is also uncertain elsewhere is kept whole")
    func deepForeignWithUncertainElsewhereIsKept() async throws {
        let vault = try makeVault()
        defer { vault.cleanUp() }
        let nested = try await trashNested(vault)
        try sealWithOtherKey(nested.deepFile)
        let other = nested.folder.diskURL.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let hidden = other.appendingPathComponent("unreadable.bin")
        try HeaderAwareTestCipher.sealed(Data("ok".utf8)).write(to: hidden)
        let restore = try restrict(hidden, to: 0o000)
        defer { restore() }

        #expect(await vault.store.hasUnreadableTrash() == false)
        try await vault.store.clearUnreadableTrash()

        restore()
        #expect(fileExists(nested.folder.diskURL))
        #expect(fileExists(nested.deepFile))
        #expect(fileExists(hidden))
    }

    @Test("A nested .vault_map sealed with the original-path context reads as readable")
    func nestedIndexWithOriginalPathContextIsReadable() async throws {
        let vault = try makeVault()
        defer { vault.cleanUp() }
        let nested = try await trashNested(vault)
        let payload = try #require(vault.indexPayload(in: nested.sub))
        try (Data("mock-sealed:Docs/Sub:".utf8) + payload).write(to: vault.indexURL(nested.sub))
        let before = try vault.snapshot()

        #expect(await vault.store.hasUnreadableTrash() == false)
        try await vault.store.clearUnreadableTrash()

        #expect(try vault.snapshot() == before)
    }

    // MARK: - 5. Cipher errors other than an authentication failure

    private static let nonAuthenticationErrors: [any Error] = [
        VaultCryptoError.noKeyLoaded, VaultCryptoError.corruptBlob, CocoaError(.fileReadUnknown),
    ]

    @Test(
        "A cipher error other than decryptionFailed on the trash index makes it uncertain: nothing cleared",
        arguments: nonAuthenticationErrors.indices)
    func trashIndexCipherErrorIsUncertain(errorIndex: Int) async throws {
        let vault = try makeVault(selective: true)
        defer { vault.cleanUp() }
        let bad = try await trashFile(vault, "bad.txt")
        try sealWithOtherKey(bad.diskURL)
        try vault.writeRawTrashMap(Self.foreignTrashIndex)
        let error = Self.nonAuthenticationErrors[errorIndex]
        vault.failing?.decryptErrorFor = { data in
            data.starts(with: Data("foreign-sealed:".utf8)) ? error : nil
        }
        let before = try vault.snapshot()

        #expect(await vault.store.hasUnreadableTrash() == false)
        _ = await caught { try await vault.store.clearUnreadableTrash() }

        #expect(try vault.snapshot() == before)
    }

    @Test(
        "A cipher error other than decryptionFailed on a nested folder index makes it uncertain: nothing cleared",
        arguments: nonAuthenticationErrors.indices)
    func folderIndexCipherErrorIsUncertain(errorIndex: Int) async throws {
        let vault = try makeVault(selective: true)
        defer { vault.cleanUp() }
        let nested = try await trashNested(vault)
        try Self.foreignIndex.write(to: nested.sub.diskURL.appendingPathComponent(".vault_map"))
        let error = Self.nonAuthenticationErrors[errorIndex]
        vault.failing?.decryptErrorFor = { data in
            data.starts(with: Data("foreign-sealed:".utf8)) ? error : nil
        }
        let before = try vault.snapshot()

        #expect(await vault.store.hasUnreadableTrash() == false)
        _ = await caught { try await vault.store.clearUnreadableTrash() }

        #expect(try vault.snapshot() == before)
    }

    // MARK: - 6. Removal failures

    @Test("Clearing a foreign trash index when .trash can't be listed throws io")
    func kindAUnlistableTrashThrowsIO() async throws {
        let vault = try makeVault()
        defer { vault.cleanUp() }
        try await trashFile(vault, "a.txt")
        try vault.writeRawTrashMap(Self.foreignTrashIndex)
        let restore = try restrict(vault.trashURL, to: 0o311)
        defer { restore() }

        let error = await caught { try await vault.store.clearUnreadableTrash() }

        restore()
        #expect(isIOError(error), "expected io, got \(String(describing: error))")
    }

    @Test("Clearing a foreign trash index with one item that can't be removed throws io and removes the others")
    func kindAOneItemStuckThrowsIO() async throws {
        let vault = try makeVault()
        defer { vault.cleanUp() }
        let stuck = try await trashFolder(vault, "Stuck", file: "in.txt")
        let other = try await trashFile(vault, "other.txt")
        let third = try await trashFolder(vault, "Third", file: "t.txt")
        try vault.writeRawTrashMap(Self.foreignTrashIndex)
        let restore = try restrict(stuck.diskURL, to: 0o500)
        defer { restore() }

        let error = await caught { try await vault.store.clearUnreadableTrash() }

        restore()
        #expect(isIOError(error), "expected io, got \(String(describing: error))")
        #expect(!fileExists(other.diskURL))
        #expect(!fileExists(third.diskURL))
        #expect(!fileExists(vault.trashMapURL))
    }

    // MARK: - 7. Second probe copy failing

    private func largeIncompleteTrashFile(_ vault: VaultStoreFixture) async throws -> (VaultItem, RestoreBox) {
        let item = try await trashFile(vault, "big.bin")
        let content = Data(repeating: 0x5A, count: 150_000)
        // Header declares more than the file holds: the first chunk is incomplete (permanent damage when read).
        try HeaderAwareTestCipher.sealed(content, declaredSize: 300_000).write(to: item.diskURL)
        let box = RestoreBox()
        let tempRoot = vault.tempRoot
        vault.failing?.onFirstStreamInfo = { copy in
            if let restore = try? restrict(copy, to: 0o444) { box.add(restore) }
            if let restore = try? restrict(copy.deletingLastPathComponent(), to: 0o555) { box.add(restore) }
            if let restore = try? restrict(copy.deletingLastPathComponent().deletingLastPathComponent(), to: 0o555) {
                box.add(restore)
            }
            if let restore = try? restrict(tempRoot, to: 0o555) { box.add(restore) }
        }
        return (item, box)
    }

    @Test("A second, larger probe copy that fails after the first succeeded is not unreadable")
    func secondProbeCopyFailureIsNotDetected() async throws {
        let vault = try makeVault(selective: true)
        defer { vault.cleanUp() }
        let (item, box) = try await largeIncompleteTrashFile(vault)
        defer { box.restoreAll() }

        let detected = await vault.store.hasUnreadableTrash()

        box.restoreAll()
        #expect(box.fired, "the probe never called streamInfo on a copy")
        #expect(detected == false)
        #expect(fileExists(item.diskURL))
    }

    @Test("A second, larger probe copy that fails after the first succeeded leaves clearing with nothing removed")
    func secondProbeCopyFailureClearsNothing() async throws {
        let vault = try makeVault(selective: true)
        defer { vault.cleanUp() }
        let (item, box) = try await largeIncompleteTrashFile(vault)
        defer { box.restoreAll() }

        _ = await caught { try await vault.store.clearUnreadableTrash() }

        box.restoreAll()
        #expect(box.fired, "the probe never called streamInfo on a copy")
        #expect(fileExists(item.diskURL))
        #expect(vault.trashEntries()?.count == 1)
    }

    @Test(
        "After a failed second probe copy, clearing while still locked removes nothing")
    func secondProbeCopyFailureThenRetryWithStillLockedFolderClearsNothing() async throws {
        let vault = try makeVault(selective: true)
        defer { vault.cleanUp() }
        let (item, box) = try await largeIncompleteTrashFile(vault)
        defer { box.restoreAll() }

        let detected = await vault.store.hasUnreadableTrash()
        #expect(box.fired, "the probe never called streamInfo on a copy")
        #expect(detected == false)

        _ = await caught { try await vault.store.clearUnreadableTrash() }
        #expect(fileExists(item.diskURL))
        #expect(vault.trashEntries()?.count == 1)

        box.restoreAll()
        let detectedAfterRestore = await vault.store.hasUnreadableTrash()
        #expect(detectedAfterRestore == true)
        try await vault.store.clearUnreadableTrash()
        #expect(!fileExists(item.diskURL))
        #expect(vault.trashEntries()?.isEmpty == true)
    }

    @Test(
        "With the temp folder unwritable from the start, a large incomplete trash file is neither detected nor cleared")
    func largeIncompleteFileWithUnwritableTempRoot() async throws {
        let vault = try makeVault(selective: true)
        defer { vault.cleanUp() }
        let item = try await trashFile(vault, "big.bin")
        try HeaderAwareTestCipher.sealed(Data(repeating: 0x5A, count: 150_000), declaredSize: 300_000)
            .write(to: item.diskURL)
        let restore = try vault.restrictStoreTempFolder()
        defer { restore() }

        let detected = await vault.store.hasUnreadableTrash()
        _ = await caught { try await vault.store.clearUnreadableTrash() }

        restore()
        #expect(detected == false)
        #expect(fileExists(item.diskURL))
        #expect(vault.trashEntries()?.count == 1)
    }

    // MARK: - 8. Chunk read errors

    private static let marker = Data(repeating: 0x42, count: 8)

    private func markedFailure(_ error: any Error) -> @Sendable (URL) -> (any Error)? {
        let marker = Self.marker
        return { url in
            guard let data = try? Data(contentsOf: url), data.count > HeaderAwareTestCipher.headerSize else {
                return nil
            }
            return data.dropFirst(HeaderAwareTestCipher.headerSize).starts(with: marker) ? error : nil
        }
    }

    @Test(
        "A chunk read error other than decryptionFailed leaves that file uncertain while a genuine failure is cleared",
        arguments: nonAuthenticationErrors.indices)
    func chunkReadErrorFileIsKeptOthersCleared(errorIndex: Int) async throws {
        let vault = try makeVault(selective: true)
        defer { vault.cleanUp() }
        let uncertain = try await trashFile(vault, "uncertain.bin")
        let bad = try await trashFile(vault, "bad.bin")
        try HeaderAwareTestCipher.sealed(Self.marker + Data("payload".utf8)).write(to: uncertain.diskURL)
        try sealWithOtherKey(bad.diskURL)
        vault.failing?.decryptChunkErrorFor = markedFailure(Self.nonAuthenticationErrors[errorIndex])

        #expect(await vault.store.hasUnreadableTrash())
        try await vault.store.clearUnreadableTrash()

        #expect(!fileExists(bad.diskURL))
        #expect(fileExists(uncertain.diskURL))
        #expect(vault.trashEntries()?.count == 1)
    }

    @Test("A chunk read error other than decryptionFailed alone is not unreadable and nothing is cleared")
    func chunkReadErrorAloneIsNotUnreadable() async throws {
        let vault = try makeVault(selective: true)
        defer { vault.cleanUp() }
        let uncertain = try await trashFile(vault, "uncertain.bin")
        try await trashFile(vault, "fine.bin")
        try HeaderAwareTestCipher.sealed(Self.marker + Data("payload".utf8)).write(to: uncertain.diskURL)
        vault.failing?.decryptChunkErrorFor = markedFailure(CocoaError(.fileReadUnknown))
        let before = try vault.snapshot()

        #expect(await vault.store.hasUnreadableTrash() == false)
        try await vault.store.clearUnreadableTrash()

        #expect(try vault.snapshot() == before)
    }

    // MARK: - 9. Unwritable temporary folder

    @Test("With an unwritable temp folder, clearing removes nothing and nothing is judged unreadable")
    func unwritableTempRootClearsNothing() async throws {
        let vault = try makeVault()
        defer { vault.cleanUp() }
        let bad = try await trashFile(vault, "bad.txt")
        let folder = try await trashFolder(vault, "Docs", file: "in.txt")
        try await trashFile(vault, "good.txt")
        try sealWithOtherKey(bad.diskURL)
        let before = try vaultState(vault)
        let restore = try vault.restrictStoreTempFolder()
        defer { restore() }

        let detected = await vault.store.hasUnreadableTrash()
        _ = await caught { try await vault.store.clearUnreadableTrash() }

        restore()
        #expect(detected == false)
        #expect(try vaultState(vault) == before)
        #expect(fileExists(folder.diskURL))
        #expect(vault.tempContents().isEmpty)
    }

    @Test("With an unwritable temp folder, trash listing and restore keep the stored encrypted flag")
    func unwritableTempRootKeepsStoredFlag() async throws {
        let vault = try makeVault()
        defer { vault.cleanUp() }
        try await trashFile(vault, "a.txt", "content")
        let restore = try vault.restrictStoreTempFolder()
        defer { restore() }

        let listed = try await vault.store.trashContents()
        let item = try #require(listed.first)
        let restored = try await vault.store.restore(item)

        restore()
        #expect(listed.count == 1)
        #expect(item.isEncrypted)
        #expect(restored.isEncrypted)
        #expect(try await vault.openedContent(restored) == "content")
    }

    @Test(
        "With an unwritable temp folder, a strict migration step over a trash file throws io",
        arguments: [true, false])
    func unwritableTempRootMigrationStepThrowsIO(toEncrypted: Bool) async throws {
        let vault = try makeVault()
        defer { vault.cleanUp() }
        try await trashFile(vault, "a.txt", "content")
        let item = try #require(try await vault.store.trashContents().first)
        let before = try vaultState(vault)
        let restore = try vault.restrictStoreTempFolder()
        defer { restore() }

        let error = await caught {
            if toEncrypted {
                try await vault.store.migrateToEncrypted(item)
            } else {
                try await vault.store.migrateToDecrypted(item)
            }
        }

        restore()
        #expect(isIOError(error), "expected io, got \(String(describing: error))")
        #expect(try vaultState(vault) == before)
        #expect(vault.tempContents().isEmpty)
    }

    // MARK: - 10. Migration-step header reads

    @Test(
        "A migration step over an unreadable trash file throws io and never treats it as plaintext",
        arguments: [true, false])
    func migrationStepUnreadableFileThrowsIO(toEncrypted: Bool) async throws {
        let vault = try makeVault()
        defer { vault.cleanUp() }
        try await trashFile(vault, "a.txt")
        let item = try #require(try await vault.store.trashContents().first)
        let before = try vaultState(vault)
        let restore = try restrict(item.diskURL, to: 0o000)
        defer { restore() }

        let error = await caught {
            if toEncrypted {
                try await vault.store.migrateToEncrypted(item)
            } else {
                try await vault.store.migrateToDecrypted(item)
            }
        }

        restore()
        #expect(isIOError(error), "expected io, got \(String(describing: error))")
        #expect(try vaultState(vault) == before)
        #expect(vault.trashEntries()?.values.first?["isEncrypted"] as? Bool == true)
        #expect(vault.tempContents().isEmpty)
    }

    @Test(
        "A key lost while reading a trash file's header throws locked, moves nothing and leaves no temp copy",
        arguments: [true, false])
    func migrationStepKeyLostThrowsLocked(toEncrypted: Bool) async throws {
        let vault = try makeVault(selective: true)
        defer { vault.cleanUp() }
        try await trashFile(vault, "a.txt")
        let item = try #require(try await vault.store.trashContents().first)
        let before = try vaultState(vault)
        vault.failing?.streamInfoError = VaultCryptoError.noKeyLoaded

        let error = await caught {
            if toEncrypted {
                try await vault.store.migrateToEncrypted(item)
            } else {
                try await vault.store.migrateToDecrypted(item)
            }
        }

        #expect(error as? VaultStoreError == .locked, "got \(String(describing: error))")
        #expect(try vaultState(vault) == before)
        #expect(vault.tempContents().isEmpty)
    }

    @Test(
        "Any other header-read error on the copy treats the trash file as plaintext",
        arguments: [VaultCryptoError.corruptBlob, VaultCryptoError.decryptionFailed])
    func migrationStepOtherHeaderErrorMeansPlaintext(error: VaultCryptoError) async throws {
        let vault = try makeVault(selective: true)
        defer { vault.cleanUp() }
        try await trashFile(vault, "a.txt")
        let item = try #require(try await vault.store.trashContents().first)
        let bytes = try Data(contentsOf: item.diskURL)
        vault.failing?.streamInfoError = error

        try await vault.store.migrateToDecrypted(item)

        // Seen as plaintext, the file is already decrypted: its bytes stay and the entry is corrected.
        #expect(try Data(contentsOf: item.diskURL) == bytes)
        #expect(vault.trashEntries()?.values.first?["isEncrypted"] as? Bool == false)
        #expect(vault.tempContents().isEmpty)
    }
}
