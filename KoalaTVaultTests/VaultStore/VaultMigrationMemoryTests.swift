import Darwin
import Foundation
import Testing
import os

@testable import KoalaTVault

/// Samples the process's physical memory footprint from a background thread, so the peak during a call is caught.
private final class FootprintSampler: Sendable {
    private let peakValue = OSAllocatedUnfairLock(initialState: UInt64(0))
    private let running = OSAllocatedUnfairLock(initialState: true)
    private let finished = DispatchSemaphore(value: 0)

    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    init() {
        peakValue.withLock { $0 = Self.footprint() }
        let thread = Thread { [self] in
            while running.withLock({ $0 }) {
                let now = Self.footprint()
                peakValue.withLock { $0 = max($0, now) }
                Thread.sleep(forTimeInterval: 0.002)
            }
            finished.signal()
        }
        thread.start()
    }

    /// Stops sampling and returns the highest footprint seen.
    func stop() -> UInt64 {
        running.withLock { $0 = false }
        finished.wait()
        return peakValue.withLock { $0 }
    }
}

/// A store over a unique temporary vault with the real cipher, so chunked reads go through the real file path.
private struct BigFileVault {
    static let fileSize = 192 * 1024 * 1024

    let base: URL
    let rootURL: URL
    let store: LiveVaultStore

    init() throws {
        let manager = FileManager.default
        base = manager.temporaryDirectory.appendingPathComponent("VaultMemory-\(UUID().uuidString)", isDirectory: true)
        rootURL = base.appendingPathComponent("Vault", isDirectory: true)
        let tempRoot = base.appendingPathComponent("Temp", isDirectory: true)
        for url in [rootURL, tempRoot] { try manager.createDirectory(at: url, withIntermediateDirectories: true) }
        let keys = MockMasterKeyStoring(password: "pw", keyLoaded: true)
        store = LiveVaultStore(
            root: rootURL, name: "KoalaTVault", isEncrypted: true, keyStore: keys,
            cipher: LiveFileCipher(keyStore: keys), temporaryRoot: tempRoot)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: base) }

    var plainURL: URL { rootURL.appendingPathComponent("big.bin") }

    /// Writes a zero-filled (sparse) file of `fileSize` bytes at `url`.
    func writeBigFile(at url: URL) throws {
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(Self.fileSize))
    }

    /// Runs `body` and returns how far the process footprint rose above its starting value at the peak.
    func peakGrowth(during body: () async throws -> Void) async throws -> Int {
        let before = Int(FootprintSampler.footprint())
        let sampler = FootprintSampler()
        do {
            try await body()
        } catch {
            _ = sampler.stop()
            throw error
        }
        return max(0, Int(sampler.stop()) - before)
    }
}

@Suite(.serialized) struct VaultMigrationMemoryTests {
    // Whole-process footprint: parallel suites can inflate the peak. The 1/4-of-file headroom
    // (48 MiB vs ~1 MiB chunks) is the guard against that noise.
    private let limit = BigFileVault.fileSize / 4

    @Test("migrateToEncrypted of a large file keeps memory growth far below the file size")
    func encryptingLargeFileKeepsMemoryBounded() async throws {
        let vault = try BigFileVault()
        defer { vault.cleanUp() }
        try vault.writeBigFile(at: vault.plainURL)
        let item = try #require(try await vault.store.itemsToMigrate(toEncrypted: true).first)

        let growth = try await vault.peakGrowth { try await vault.store.migrateToEncrypted(item) }

        #expect(!FileManager.default.fileExists(atPath: vault.plainURL.path))
        #expect(try await vault.store.hasUnencryptedFiles() == false)
        #expect(growth < limit, "memory grew by \(growth / 1_048_576) MiB")
    }

    @Test("migrateToEncrypted of a plaintext whose matching copy already exists removes it within bounded memory")
    func rerunWithMatchingCopyKeepsMemoryBounded() async throws {
        let vault = try BigFileVault()
        defer { vault.cleanUp() }
        let backup = vault.base.appendingPathComponent("backup.bin")
        try vault.writeBigFile(at: vault.plainURL)
        try FileManager.default.copyItem(at: vault.plainURL, to: backup)
        let first = try #require(try await vault.store.itemsToMigrate(toEncrypted: true).first)
        try await vault.store.migrateToEncrypted(first)
        // An earlier run killed before removing the plaintext: the plaintext is back next to its indexed copy.
        try FileManager.default.copyItem(at: backup, to: vault.plainURL)
        let rerun = try #require(try await vault.store.itemsToMigrate(toEncrypted: true).first)

        let growth = try await vault.peakGrowth { try await vault.store.migrateToEncrypted(rerun) }

        #expect(!FileManager.default.fileExists(atPath: vault.plainURL.path))
        let diskNames = try FileManager.default.contentsOfDirectory(atPath: vault.rootURL.path)
        #expect(diskNames.filter { UUID(uuidString: $0) != nil }.count == 1)
        #expect(growth < limit, "memory grew by \(growth / 1_048_576) MiB")
    }
}
