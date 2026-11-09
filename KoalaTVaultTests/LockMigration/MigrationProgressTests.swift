import Foundation
import Testing

@testable import KoalaTVault

// MigrationProgress.swift has no behavior of its own in the memo's spec: the progress it tracks is what
// `LockMigrating.phase` and `phaseUpdates()` publish, so these tests check the published progress through the migrator.

@MainActor
private func collect(
    _ stream: AsyncStream<MigrationPhase>,
    until isLast: @escaping @Sendable (MigrationPhase) -> Bool
) -> Task<[MigrationPhase], Never> {
    Task {
        var phases: [MigrationPhase] = []
        for await phase in stream {
            phases.append(phase)
            if isLast(phase) { break }
        }
        return phases
    }
}

private func isFinal(_ phase: MigrationPhase) -> Bool {
    switch phase {
    case .completed, .failed, .paused: true
    case .unreadableTrash: true  // feature device-fixes: new phase added (a stop, like .failed)
    case .idle, .running: false
    }
}

private func isRunning(_ phase: MigrationPhase) -> Bool {
    if case .running = phase { return true }
    return false
}

@MainActor
@Suite struct MigrationProgressTests {
    private func plaintextHarness() -> MigrationHarness {
        MigrationHarness(files: MigrationHarness.sampleFiles(encrypted: false))
    }

    @Test("A migrator that has not started is idle")
    func startsIdle() {
        let harness = plaintextHarness()
        #expect(harness.migrator.phase == .idle)
    }

    @Test("Progress starts at running(0, total) and counts every file, trash included")
    func progressStartsAtZeroOfTotal() async {
        let harness = plaintextHarness()
        let collected = collect(harness.migrator.phaseUpdates(), until: isFinal)
        await harness.migrator.start(.encrypt, target: .password)
        let phases = await collected.value
        #expect(phases.first == .running(done: 0, total: 4))
        #expect(phases.last == .completed(fully: true))
    }

    @Test("Each completed file advances the done count by one, never past the total")
    func doneCountAdvancesByOne() async {
        let harness = plaintextHarness()
        let collected = collect(harness.migrator.phaseUpdates(), until: isFinal)
        await harness.migrator.start(.encrypt, target: .password)
        let phases = await collected.value
        let doneCounts: [Int] = phases.compactMap {
            if case .running(let done, let total) = $0 {
                #expect(total == 4)
                return done
            }
            return nil
        }
        #expect(doneCounts.first == 0)
        #expect(zip(doneCounts, doneCounts.dropFirst()).allSatisfy { $1 == $0 + 1 })
        #expect(doneCounts.allSatisfy { $0 <= 4 })
    }

    @Test("Every phase change is published once, and the phase property ends on the last one published")
    func eachChangePublishedOnce() async {
        let harness = plaintextHarness()
        let collected = collect(harness.migrator.phaseUpdates(), until: isFinal)
        await harness.migrator.start(.encrypt, target: .password)
        let phases = await collected.value
        #expect(zip(phases, phases.dropFirst()).allSatisfy { $0 != $1 })
        #expect(phases.last == harness.migrator.phase)
    }

    @Test("A decrypt migration publishes its progress the same way")
    func decryptProgress() async {
        let harness = MigrationHarness(files: MigrationHarness.sampleFiles(encrypted: true))
        let collected = collect(harness.migrator.phaseUpdates(), until: isFinal)
        await harness.migrator.start(.decrypt, target: nil)
        let phases = await collected.value
        #expect(phases.first == .running(done: 0, total: 4))
        #expect(phases.last == .completed(fully: true))
    }

    @Test("A migration with failures ends by publishing failed with the names")
    func failureIsPublished() async {
        let harness = plaintextHarness()
        harness.store.setFailure(.io("bad"), for: "c.mov")
        let collected = collect(harness.migrator.phaseUpdates(), until: isFinal)
        await harness.migrator.start(.encrypt, target: .password)
        let phases = await collected.value
        #expect(phases.last == .failed(names: ["c.mov"]))
    }

    @Test("A key wipe publishes paused with the files done so far and the total")
    func pauseIsPublished() async {
        let harness = plaintextHarness()
        let collected = collect(harness.migrator.phaseUpdates(), until: isFinal)
        harness.gate.arm(at: "migrate:c.mov")
        let task = Task { await harness.migrator.start(.encrypt, target: .password) }
        #expect(await waitUntil { harness.gate.hasReached("migrate:c.mov") })
        harness.lock.wipeKey()
        harness.gate.release()
        await task.value
        let phases = await collected.value
        #expect(phases.last == .paused(done: 2, total: 4))
    }

    @Test("Resuming after a pause publishes running again and then completed")
    func resumeIsPublished() async {
        let harness = plaintextHarness()
        harness.gate.arm(at: "migrate:c.mov")
        let task = Task { await harness.migrator.start(.encrypt, target: .password) }
        #expect(await waitUntil { harness.gate.hasReached("migrate:c.mov") })
        harness.lock.wipeKey()
        harness.gate.release()
        await task.value
        let collected = collect(harness.migrator.phaseUpdates()) { $0 == .completed(fully: true) }
        harness.lock.restoreKey()
        await harness.migrator.resumeIfPending()
        let phases = await collected.value
        #expect(phases.contains(where: isRunning))
        #expect(phases.last == .completed(fully: true))
    }

    @Test("Skipping failures publishes completed(fully: false)")
    func skipIsPublished() async {
        let harness = plaintextHarness()
        harness.store.setFailure(.io("bad"), for: "c.mov")
        await harness.migrator.start(.encrypt, target: .password)
        let collected = collect(harness.migrator.phaseUpdates()) { $0 == .completed(fully: false) }
        await harness.migrator.skipFailed()
        let phases = await collected.value
        #expect(phases == [.completed(fully: false)])
    }

    @Test("Two subscribers each receive the phase changes")
    func twoSubscribers() async {
        let harness = plaintextHarness()
        let first = collect(harness.migrator.phaseUpdates(), until: isFinal)
        let second = collect(harness.migrator.phaseUpdates(), until: isFinal)
        await harness.migrator.start(.encrypt, target: .password)
        let firstPhases = await first.value
        let secondPhases = await second.value
        #expect(firstPhases == secondPhases)
        #expect(firstPhases.last == .completed(fully: true))
    }
}
