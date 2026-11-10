import Foundation
import Testing

@testable import KoalaTVault

@Suite struct LaunchTemporaryFilesTests {
    /// A unique container folder for one test, created on disk.
    private func makeContainer() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchTemporaryFilesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cleanUp(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Creates a folder named `name` inside `container` holding one file.
    @discardableResult
    private func makeFolder(_ name: String, in container: URL) throws -> URL {
        let folder = container.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: folder.appendingPathComponent("file.bin"))
        return folder
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    @Test("A launch root is a direct child of the given container")
    func launchRootIsChildOfContainer() throws {
        let container = try makeContainer()
        defer { cleanUp(container) }
        let root = LaunchTemporaryFiles.makeLaunchRoot(in: container)
        #expect(root.deletingLastPathComponent().standardizedFileURL == container.standardizedFileURL)
        #expect(!root.lastPathComponent.isEmpty)
    }

    @Test("Each call makes a different launch root")
    func launchRootsDiffer() throws {
        let container = try makeContainer()
        defer { cleanUp(container) }
        let first = LaunchTemporaryFiles.makeLaunchRoot(in: container)
        let second = LaunchTemporaryFiles.makeLaunchRoot(in: container)
        #expect(first != second)
    }

    @Test("Making a launch root does not create it on disk")
    func launchRootNotCreated() throws {
        let container = try makeContainer()
        defer { cleanUp(container) }
        let root = LaunchTemporaryFiles.makeLaunchRoot(in: container)
        #expect(!exists(root))
        let contents = try FileManager.default.contentsOfDirectory(atPath: container.path)
        #expect(contents.isEmpty)
    }

    @Test("Leftovers are the other entries of the container, never the kept launch root")
    func leftoversExcludeKeptRoot() throws {
        let container = try makeContainer()
        defer { cleanUp(container) }
        let kept = try makeFolder("A", in: container)
        let other1 = try makeFolder("B", in: container)
        let other2 = try makeFolder("D", in: container)
        let result = LaunchTemporaryFiles.leftovers(keeping: kept, in: container)
        #expect(Set(result.map(\.lastPathComponent)) == ["B", "D"])
        #expect(result.count == 2)
        #expect(!result.contains { $0.lastPathComponent == kept.lastPathComponent })
        #expect(Set(result.map { $0.standardizedFileURL.path }) ==
            Set([other1, other2].map { $0.standardizedFileURL.path }))
    }

    @Test("Leftovers of a container holding only the kept root are empty")
    func leftoversEmptyWhenOnlyKept() throws {
        let container = try makeContainer()
        defer { cleanUp(container) }
        let kept = try makeFolder("A", in: container)
        #expect(LaunchTemporaryFiles.leftovers(keeping: kept, in: container).isEmpty)
    }

    @Test("Leftovers of a missing container are empty")
    func leftoversOfMissingContainer() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchTemporaryFilesTests-missing-\(UUID().uuidString)", isDirectory: true)
        let kept = missing.appendingPathComponent("A", isDirectory: true)
        #expect(LaunchTemporaryFiles.leftovers(keeping: kept, in: missing).isEmpty)
    }

    @Test("Removing entries deletes them with their contents and leaves the kept root untouched")
    func removeDeletesEntriesOnly() throws {
        let container = try makeContainer()
        defer { cleanUp(container) }
        let kept = try makeFolder("A", in: container)
        let other1 = try makeFolder("B", in: container)
        let other2 = try makeFolder("D", in: container)
        LaunchTemporaryFiles.remove([other1, other2])
        #expect(!exists(other1))
        #expect(!exists(other1.appendingPathComponent("file.bin")))
        #expect(!exists(other2))
        #expect(exists(kept))
        #expect(exists(kept.appendingPathComponent("file.bin")))
    }

    @Test("Removing skips a missing entry and still removes the others")
    func removeSkipsMissingEntry() throws {
        let container = try makeContainer()
        defer { cleanUp(container) }
        let kept = try makeFolder("A", in: container)
        let present = try makeFolder("B", in: container)
        let missing = container.appendingPathComponent("gone", isDirectory: true)
        LaunchTemporaryFiles.remove([missing, present])
        #expect(!exists(present))
        #expect(exists(kept))
    }

    @Test("Removing an empty list changes nothing")
    func removeEmptyList() throws {
        let container = try makeContainer()
        defer { cleanUp(container) }
        let kept = try makeFolder("A", in: container)
        LaunchTemporaryFiles.remove([])
        #expect(exists(kept))
    }

    @Test("Leftovers then remove clears earlier launches and keeps this launch's root")
    func leftoversThenRemoveEndToEnd() throws {
        let container = try makeContainer()
        defer { cleanUp(container) }
        let kept = try makeFolder("A", in: container)
        try makeFolder("B", in: container)
        try makeFolder("D", in: container)
        LaunchTemporaryFiles.remove(LaunchTemporaryFiles.leftovers(keeping: kept, in: container))
        let remaining = try FileManager.default.contentsOfDirectory(atPath: container.path)
        #expect(remaining == ["A"])
    }

    @Test("The container is StoreTemporaryFiles under the temporary directory")
    func containerLocation() {
        let expected = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreTemporaryFiles", isDirectory: true)
        #expect(LaunchTemporaryFiles.container.standardizedFileURL.path == expected.standardizedFileURL.path)
    }

    @Test("The pre-update folder is VaultStore under the temporary directory")
    func preUpdateFolderLocation() {
        let expected = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultStore", isDirectory: true)
        #expect(LaunchTemporaryFiles.preUpdateFolder.standardizedFileURL.path == expected.standardizedFileURL.path)
    }
}
