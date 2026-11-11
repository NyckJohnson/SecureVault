import Foundation
import Testing

@testable import KoalaTVault

@MainActor
@Suite struct LiveLockMigratorFailureTests {
    @Test("A failing file does not stop the others; the run ends failed with its display name")
    func failedFileIsCollected() async {
        let harness = MigrationHarness()
        harness.store.setFailure(.io("bad"), for: "b.pdf")
        await harness.run()
        #expect(harness.migrator.phase == .failed(names: ["b.pdf"]))
        #expect(harness.store.isEncrypted("a.jpg") == true)
        #expect(harness.store.isEncrypted("b.pdf") == false)
        #expect(harness.store.isEncrypted("c.mov") == true)
        #expect(harness.store.isEncrypted("Old.txt") == true)
    }

    @Test("Several failed files are reported by display name in listed order, a trashed file included")
    func failedNamesInListedOrder() async {
        let harness = MigrationHarness()
        harness.store.setFailure(.io("bad"), for: "c.mov")
        harness.store.setFailure(.io("bad"), for: "Old.txt")
        harness.store.setFailure(.notFound, for: "a.jpg")
        await harness.run()
        #expect(harness.migrator.phase == .failed(names: ["a.jpg", "c.mov", "Old.txt"]))
    }

    @Test("Retry encrypts only the failed files again")
    func retryOnlyFailedFiles() async {
        let harness = MigrationHarness()
        harness.store.setFailure(.io("bad"), for: "b.pdf")
        await harness.run()
        harness.store.setFailure(nil, for: "b.pdf")
        await harness.migrator.retryFailed()
        #expect(harness.migrator.phase == .completed(fully: true))
        #expect(harness.store.isEncrypted("b.pdf") == true)
        #expect(harness.log.events(withPrefix: "enc:").filter { $0 == "enc:a.jpg" }.count == 1)
        #expect(harness.log.events(withPrefix: "enc:").filter { $0 == "enc:b.pdf" }.count == 2)
        #expect(harness.log.count(of: "enc:c.mov") == 1)
    }

    @Test("Retry publishes running first, so a repeated failure is published again")
    func retryPublishesRunningBeforeRepeatFailure() async {
        let harness = MigrationHarness()
        harness.store.setFailure(.io("bad"), for: "b.pdf")
        await harness.run()
        let recorder = harness.recorder()
        await harness.migrator.retryFailed()
        await recorder.wait { $0 == .failed(names: ["b.pdf"]) }
        await recorder.finish()
        #expect(recorder.phases == [.running(done: 0, total: 1), .running(done: 1, total: 1), .failed(names: ["b.pdf"])]
            || recorder.phases == [.running(done: 0, total: 1), .failed(names: ["b.pdf"])])
        #expect(harness.migrator.phase == .failed(names: ["b.pdf"]))
    }

    @Test("Retry that succeeds ends completed(fully: true)")
    func retrySucceeds() async {
        let harness = MigrationHarness()
        harness.store.setFailure(.io("bad"), for: "a.jpg")
        harness.store.setFailure(.io("bad"), for: "c.mov")
        await harness.run()
        harness.store.setFailure(nil, for: "a.jpg")
        harness.store.setFailure(nil, for: "c.mov")
        await harness.migrator.retryFailed()
        #expect(harness.migrator.phase == .completed(fully: true))
    }

    @Test("Retry when nothing failed does nothing")
    func retryWhenNotFailed() async {
        let harness = MigrationHarness()
        await harness.migrator.retryFailed()
        #expect(harness.migrator.phase == .idle)
        #expect(harness.log.events.isEmpty)
    }

    @Test("Skip gives up on the failed files: completed(fully: false), nothing encrypted again")
    func skipFailed() async {
        let harness = MigrationHarness()
        harness.store.setFailure(.io("bad"), for: "c.mov")
        await harness.run()
        await harness.migrator.skipFailed()
        #expect(harness.migrator.phase == .completed(fully: false))
        #expect(harness.log.count(of: "enc:c.mov") == 1)
        #expect(harness.store.isEncrypted("c.mov") == false)
    }

    @Test("A listing failure ends the run failed with no names")
    func listingFailure() async {
        let harness = MigrationHarness()
        harness.store.setListingFailure(.io("cannot list"))
        await harness.run()
        #expect(harness.migrator.phase == .failed(names: []))
        #expect(harness.log.events(withPrefix: "enc:").isEmpty)
    }

    @Test("Retry after a listing failure lists again and encrypts everything")
    func retryRedoesListing() async {
        let harness = MigrationHarness()
        harness.store.setListingFailure(.io("cannot list"))
        await harness.run()
        harness.store.setListingFailure(nil)
        await harness.migrator.retryFailed()
        #expect(harness.migrator.phase == .completed(fully: true))
        #expect(harness.log.count(of: "list") == 2)
        for name in MigrationHarness.names { #expect(harness.store.isEncrypted(name) == true) }
    }

    @Test("A listing failure that repeats on retry is published again")
    func listingFailureRepeats() async {
        let harness = MigrationHarness()
        harness.store.setListingFailure(.io("cannot list"))
        await harness.run()
        let recorder = harness.recorder()
        await harness.migrator.retryFailed()
        await recorder.wait { $0 == .failed(names: []) }
        await recorder.finish()
        #expect(recorder.runningCount >= 1)
        #expect(recorder.phases.last == .failed(names: []))
    }

    @Test("Skip after a listing failure ends completed(fully: false)")
    func skipAfterListingFailure() async {
        let harness = MigrationHarness()
        harness.store.setListingFailure(.io("cannot list"))
        await harness.run()
        await harness.migrator.skipFailed()
        #expect(harness.migrator.phase == .completed(fully: false))
    }

    @Test("finishEncryption failing with the key loaded is logged and the run still completes")
    func finishEncryptionFailureStillCompletes() async {
        let harness = MigrationHarness()
        harness.store.setFinishFailure(.io("cannot finish"))
        await harness.run()
        #expect(harness.migrator.phase == .completed(fully: true))
        for name in MigrationHarness.names { #expect(harness.store.isEncrypted(name) == true) }
        #expect(harness.log.count(of: "finishEncryption") >= 1)
    }

    @Test("Skip when nothing failed does nothing")
    func skipWhenNotFailed() async {
        let harness = MigrationHarness()
        await harness.migrator.skipFailed()
        #expect(harness.migrator.phase == .idle)
    }
}
