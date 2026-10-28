import Foundation
import Testing

@testable import KoalaTVault

@Suite struct VaultTempFilesTests {
    private func resolved(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }

    private func isDirectory(_ url: URL) -> Bool {
        var flag: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &flag) && flag.boolValue
    }

    @Test("makeTempDirectory creates an existing folder under the temporary root")
    func makeTempDirectoryCreatesFolder() throws {
        let vault = try VaultStoreFixture()
        defer { vault.cleanUp() }
        let url = try vault.store.makeTempDirectory()
        #expect(isDirectory(url))
        #expect(resolved(url).hasPrefix(resolved(vault.tempRoot) + "/"))
        #expect(resolved(url) != resolved(vault.tempRoot))
    }

    @Test("makeTempDirectory returns a different folder every time")
    func makeTempDirectoryIsUnique() throws {
        let vault = try VaultStoreFixture()
        defer { vault.cleanUp() }
        let urls = try (0..<5).map { _ in try vault.store.makeTempDirectory() }
        #expect(Set(urls.map(resolved)).count == 5)
        #expect(urls.allSatisfy(isDirectory))
    }

    @Test("makeTempDirectory needs no key and no lock mode", arguments: [LockMode.none, .password])
    func makeTempDirectoryNeedsNoKey(mode: LockMode) throws {
        let vault = try VaultStoreFixture(lockMode: mode, keyLoaded: false)
        defer { vault.cleanUp() }
        #expect(isDirectory(try vault.store.makeTempDirectory()))
    }

    @Test("makeTempDirectory creates the temporary root if it is missing")
    func makeTempDirectoryCreatesRoot() throws {
        let vault = try VaultStoreFixture()
        defer { vault.cleanUp() }
        try FileManager.default.removeItem(at: vault.tempRoot)
        let url = try vault.store.makeTempDirectory()
        #expect(isDirectory(url))
    }

    @Test("removeTemporary removes a temporary folder with its contents and leaves the others")
    func removeTemporaryRemovesOne() throws {
        let vault = try VaultStoreFixture()
        defer { vault.cleanUp() }
        let doomed = try vault.store.makeTempDirectory()
        let kept = try vault.store.makeTempDirectory()
        try Data("x".utf8).write(to: doomed.appendingPathComponent("file.txt"))
        try Data("y".utf8).write(to: kept.appendingPathComponent("file.txt"))
        vault.store.removeTemporary(doomed)
        #expect(!FileManager.default.fileExists(atPath: doomed.path))
        #expect(FileManager.default.fileExists(atPath: kept.appendingPathComponent("file.txt").path))
    }

    @Test("removeTemporary removes a single temporary file")
    func removeTemporaryRemovesFile() throws {
        let vault = try VaultStoreFixture()
        defer { vault.cleanUp() }
        let folder = try vault.store.makeTempDirectory()
        let file = folder.appendingPathComponent("file.txt")
        try Data("x".utf8).write(to: file)
        vault.store.removeTemporary(file)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(isDirectory(folder))
    }

    @Test("removeTemporary of a missing URL does nothing")
    func removeTemporaryMissing() throws {
        let vault = try VaultStoreFixture()
        defer { vault.cleanUp() }
        let kept = try vault.store.makeTempDirectory()
        vault.store.removeTemporary(vault.tempRoot.appendingPathComponent("missing"))
        #expect(isDirectory(kept))
    }

    @Test("removeAllTemporaryFiles removes every folder the store created")
    func removeAllRemovesStoreFolders() throws {
        let vault = try VaultStoreFixture()
        defer { vault.cleanUp() }
        let folders = try (0..<3).map { _ in try vault.store.makeTempDirectory() }
        for folder in folders { try Data("x".utf8).write(to: folder.appendingPathComponent("f.txt")) }
        vault.store.removeAllTemporaryFiles()
        #expect(folders.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(vault.tempContents().isEmpty)
    }

    @Test("removeAllTemporaryFiles removes decrypted copies made by open and keeps the vault intact")
    func removeAllRemovesOpenedCopies() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let item = try await vault.add("Report.pdf", "pdf bytes")
        let opened = try await vault.store.open(item)
        #expect(FileManager.default.fileExists(atPath: opened.path))
        vault.store.removeAllTemporaryFiles()
        #expect(!FileManager.default.fileExists(atPath: opened.path))
        #expect(vault.tempFiles().isEmpty)
        #expect(try await vault.names() == ["Report.pdf"])
        #expect(try await vault.openedContent(item) == "pdf bytes")
    }

    @Test("removeAllTemporaryFiles with nothing to remove does nothing")
    func removeAllWhenEmpty() throws {
        let vault = try VaultStoreFixture()
        defer { vault.cleanUp() }
        vault.store.removeAllTemporaryFiles()
        let url = try vault.store.makeTempDirectory()
        #expect(isDirectory(url))
    }
}
