import Foundation
import Testing

@testable import KoalaTVault

// MigrationProgress.swift has no behavior of its own in the memo's spec: the progress it tracks is what
// `LockMigrating.phase` and `phaseUpdates()` publish, so these tests check the published progress through the migrator.

@MainActor
@Suite struct MigrationProgressTests {
    @Test("Progress starts at running(0, total) and counts every file, trash included")
    func progressStartsAtZeroOfTotal() async {
        let harness = MigrationHarness()
        let recorder = harness.recorder()
        await harness.run()
        await recorder.wait { $0 == .completed(fully: true) }
        #expect(recorder.phases.first == .running(done: 0, total: 4))
    }

    @Test("Each processed file advances the done count by one, never past the total")
    func doneCountAdvancesByOne() async {
        let harness = MigrationHarness()
        let recorder = harness.recorder()
        await harness.run()
        await recorder.wait { $0 == .completed(fully: true) }
        await recorder.finish()
        let counts: [Int] = recorder.phases.compactMap {
            if case .running(let done, _) = $0 { return done }
            return nil
        }
        #expect(counts.first == 0)
        #expect(zip(counts, counts.dropFirst()).allSatisfy { $1 == $0 + 1 })
        #expect(counts.allSatisfy { $0 <= 4 })
    }

    @Test("A failed file still counts as processed: progress reaches the total before failed is published")
    func failedFileCountsAsProcessed() async {
        let harness = MigrationHarness()
        harness.store.setFailure(.io("bad"), for: "b.pdf")
        let recorder = harness.recorder()
        await harness.run()
        await recorder.wait { $0 == .failed(names: ["b.pdf"]) }
        await recorder.finish()
        let counts: [Int] = recorder.phases.compactMap {
            if case .running(let done, _) = $0 { return done }
            return nil
        }
        #expect(counts.first == 0)
        #expect(zip(counts, counts.dropFirst()).allSatisfy { $1 == $0 + 1 })
        #expect(recorder.phases.last == .failed(names: ["b.pdf"]))
    }

    @Test("A retry's progress is over the failed files only")
    func retryProgressCoversFailedFiles() async {
        let harness = MigrationHarness()
        harness.store.setFailure(.io("bad"), for: "a.jpg")
        harness.store.setFailure(.io("bad"), for: "c.mov")
        await harness.run()
        harness.store.setFailure(nil, for: "a.jpg")
        harness.store.setFailure(nil, for: "c.mov")
        let recorder = harness.recorder()
        await harness.migrator.retryFailed()
        await recorder.wait { $0 == .completed(fully: true) }
        #expect(recorder.phases.first == .running(done: 0, total: 2))
    }

    @Test("A migrator publishes failed with the names, and skipping publishes completed(fully: false)")
    func failureAndSkipArePublished() async {
        let harness = MigrationHarness()
        harness.store.setFailure(.io("bad"), for: "c.mov")
        await harness.run()
        let recorder = harness.recorder()
        await harness.migrator.skipFailed()
        await recorder.wait { $0 == .completed(fully: false) }
        await recorder.finish()
        #expect(recorder.phases == [.completed(fully: false)])
    }

    @Test("Two subscribers each receive the same phase changes")
    func twoSubscribers() async {
        let harness = MigrationHarness()
        let first = harness.recorder()
        let second = harness.recorder()
        await harness.run()
        await first.wait { $0 == .completed(fully: true) }
        await second.wait { $0 == .completed(fully: true) }
        await first.finish()
        await second.finish()
        #expect(first.phases == second.phases)
        #expect(first.phases.last == .completed(fully: true))
    }

    @Test("A subscriber hears only changes made after it subscribed")
    func subscriberHearsLaterChangesOnly() async {
        let harness = MigrationHarness()
        await harness.run()
        let recorder = harness.recorder()
        await recorder.finish()
        #expect(recorder.phases.isEmpty)
        #expect(harness.migrator.phase == .completed(fully: true))
    }
}
