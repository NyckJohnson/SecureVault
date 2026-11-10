import Foundation
import Testing

@testable import KoalaTVault

/// Create, add, copy and rename when the disk or the cipher fails: the error is reported and nothing is left behind.
@Suite struct VaultFileOperationsFailureTests {
    enum SealFailure: String, CaseIterable, Sendable {
        case noKey, other

        var cryptoError: VaultCryptoError { self == .noKey ? .noKeyLoaded : .encryptionFailed }
        func matches(_ error: (any Error)?) -> Bool {
            self == .noKey ? error as? VaultStoreError == .locked : isIOError(error)
        }
    }

    // MARK: - createFolder

    @Test(
        "createFolder in a read-only parent throws io and creates nothing",
        arguments: [LockMode.none, .password])
    func createFolderInReadOnlyParent(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode)
        defer { vault.cleanUp() }
        let restore = try restrict(vault.rootURL)
        defer { restore() }

        let error = await caught { _ = try await vault.store.createFolder(named: "Photos", in: vault.root) }

        restore()
        #expect(isIOError(error), "expected io, got \(String(describing: error))")
        #expect(try vault.diskNames().isEmpty)
    }

    // MARK: - addFile

    @Test("A plaintext addFile into a read-only folder throws io and writes nothing")
    func plaintextAddFileInReadOnlyFolder() async throws {
        let vault = try VaultStoreFixture()
        defer { vault.cleanUp() }
        let source = try vault.source("a.txt", "data")
        let restore = try restrict(vault.rootURL)
        defer { restore() }

        let error = await caught { _ = try await vault.store.addFile(from: source, named: "a.txt", to: vault.root) }

        restore()
        #expect(isIOError(error), "expected io, got \(String(describing: error))")
        #expect(try vault.diskNames().isEmpty)
        #expect(try vault.content(source) == "data")
    }

    @Test("A plaintext addFile into a folder that was removed throws and writes nothing")
    func plaintextAddFileInRemovedFolder() async throws {
        let vault = try VaultStoreFixture()
        defer { vault.cleanUp() }
        let gone = try vault.folder("Gone")
        try FileManager.default.removeItem(at: gone.diskURL)
        let source = try vault.source("a.txt", "data")

        let error = await caught { _ = try await vault.store.addFile(from: source, named: "a.txt", to: gone) }

        #expect(error is VaultStoreError)
        #expect(!FileManager.default.fileExists(atPath: gone.diskURL.path))
        #expect(try vault.diskNames().isEmpty)
    }

    @Test(
        "An encrypted addFile whose encryption reports a missing file throws io, not notFound, and leaves nothing",
        arguments: [LockMode.password, .passwordAndBiometrics])
    func encryptedAddFileMissingFileIsIO(mode: LockMode) async throws {
        let vault = try VaultStoreFixture(lockMode: mode, selective: true)
        defer { vault.cleanUp() }
        let source = try vault.source("a.txt", "data")
        let failing = try #require(vault.failing)
        failing.encryptFileError = CocoaError(.fileNoSuchFile)

        let error = await caught { _ = try await vault.store.addFile(from: source, named: "a.txt", to: vault.root) }

        #expect(isIOError(error), "expected io, got \(String(describing: error))")
        #expect(try vault.diskNames().isEmpty)
        #expect(vault.rawIndex() == nil)
    }

    @Test("An encrypted addFile whose file encryption fails throws and leaves no file and no index entry")
    func encryptedAddFileEncryptionFails() async throws {
        let vault = try VaultStoreFixture(lockMode: .password, selective: true)
        defer { vault.cleanUp() }
        let existing = try await vault.add("old.txt", "old")
        let indexBefore = vault.rawIndex()
        let diskBefore = try vault.diskNames()
        let source = try vault.source("a.txt", "data")
        let failing = try #require(vault.failing)
        failing.encryptFileError = VaultCryptoError.encryptionFailed

        let error = await caught { _ = try await vault.store.addFile(from: source, named: "a.txt", to: vault.root) }

        #expect(isIOError(error), "expected io, got \(String(describing: error))")
        #expect(try vault.diskNames() == diskBefore)
        #expect(vault.rawIndex() == indexBefore)
        #expect(vault.indexEntries()?.values.sorted() == ["old.txt"])
        #expect(try await vault.openedContent(existing) == "old")
    }

    @Test(
        "An encrypted addFile whose index write fails removes the new file and throws",
        arguments: SealFailure.allCases)
    func encryptedAddFileIndexWriteFails(failure: SealFailure) async throws {
        let vault = try VaultStoreFixture(lockMode: .password, selective: true)
        defer { vault.cleanUp() }
        let source = try vault.source("a.txt", "data")
        let failing = try #require(vault.failing)
        failing.encryptError = failure.cryptoError

        let error = await caught { _ = try await vault.store.addFile(from: source, named: "a.txt", to: vault.root) }

        #expect(failure.matches(error), "unexpected error \(String(describing: error))")
        #expect(try vault.diskNames().isEmpty)
        #expect(vault.rawIndex() == nil)
    }

    // MARK: - copy

    @Test("Copying a plaintext file into a read-only folder throws io and copies nothing")
    func plaintextCopyIntoReadOnlyFolder() async throws {
        let vault = try VaultStoreFixture()
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        let item = try await vault.add("a.txt", "data")
        let restore = try restrict(docs.diskURL)
        defer { restore() }

        let error = await caught { _ = try await vault.store.copy(item, to: docs) }

        restore()
        #expect(isIOError(error), "expected io, got \(String(describing: error))")
        #expect(try vault.diskNames(in: docs).isEmpty)
        #expect(try vault.content(item.diskURL) == "data")
    }

    @Test("Copying an encrypted file into a read-only folder throws io and leaves no file and no entry")
    func encryptedCopyIntoReadOnlyFolder() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        let item = try await vault.add("a.txt", "data")
        let restore = try restrict(docs.diskURL)
        defer { restore() }

        let error = await caught { _ = try await vault.store.copy(item, to: docs) }

        restore()
        #expect(isIOError(error), "expected io, got \(String(describing: error))")
        #expect(try vault.diskNames(in: docs).isEmpty)
        #expect(vault.rawIndex(in: docs) == nil)
        #expect(try await vault.openedContent(item) == "data")
    }

    @Test(
        "Copying an encrypted file whose target index write fails removes the copy and throws",
        arguments: SealFailure.allCases)
    func encryptedCopyIndexWriteFails(failure: SealFailure) async throws {
        let vault = try VaultStoreFixture(lockMode: .password, selective: true)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        let item = try await vault.add("a.txt", "data")
        let rootIndexBefore = vault.rawIndex()
        let failing = try #require(vault.failing)
        failing.encryptError = failure.cryptoError

        let error = await caught { _ = try await vault.store.copy(item, to: docs) }

        failing.encryptError = nil
        #expect(failure.matches(error), "unexpected error \(String(describing: error))")
        #expect(try vault.diskNames(in: docs).isEmpty)
        #expect(vault.rawIndex(in: docs) == nil)
        #expect(vault.rawIndex() == rootIndexBefore)
        #expect(try await vault.openedContent(item) == "data")
    }

    // MARK: - rename

    @Test("Renaming a plaintext file in a read-only folder throws io and keeps the name")
    func plaintextRenameInReadOnlyFolder() async throws {
        let vault = try VaultStoreFixture()
        defer { vault.cleanUp() }
        let item = try await vault.add("a.txt", "data")
        let restore = try restrict(vault.rootURL)
        defer { restore() }

        let error = await caught { _ = try await vault.store.rename(item, to: "b.txt") }

        restore()
        #expect(isIOError(error), "expected io, got \(String(describing: error))")
        #expect(try vault.diskNames() == ["a.txt"])
        #expect(try vault.content(item.diskURL) == "data")
    }
}
