import Foundation
import Testing

@testable import KoalaTVault

@MainActor
@Suite struct LiveLockMigratorTests {
    @Test("A migrator that has not run is idle")
    func startsIdle() {
        #expect(MigrationHarness().migrator.phase == .idle)
    }

    @Test("encryptLeftovers encrypts every plaintext file, trash included")
    func encryptsEveryLeftover() async {
        let harness = MigrationHarness()
        await harness.run()
        for name in MigrationHarness.names { #expect(harness.store.isEncrypted(name) == true) }
        #expect(harness.migrator.phase == .completed(fully: true))
    }

    @Test("It lists first, encrypts one file at a time in listed order, then calls finishEncryption")
    func listsThenEncryptsOneAtATimeThenFinishes() async {
        let harness = MigrationHarness()
        await harness.run()
        let events = harness.log.events
        #expect(events.first == "list")
        let steps = events.filter { $0.hasPrefix("enc") }
        let expected = MigrationHarness.names.flatMap { ["enc:\($0)", "enc-done:\($0)"] }
        #expect(steps == expected)
        let lastDone = events.lastIndex(of: "enc-done:Old.txt")
        let finish = events.lastIndex(of: "finishEncryption")
        #expect(lastDone != nil && finish != nil)
        if let lastDone, let finish { #expect(lastDone < finish) }
        #expect(harness.log.count(of: "finishEncryption") == 1)
    }

    @Test("The phase goes from running(0, n) up one file at a time to completed(fully: true)")
    func phaseSequence() async {
        let harness = MigrationHarness()
        let recorder = harness.recorder()
        await harness.run()
        await recorder.wait { $0 == .completed(fully: true) }
        await recorder.finish()
        #expect(recorder.phases.first == .running(done: 0, total: 4))
        #expect(recorder.phases.last == .completed(fully: true))
        let counts: [Int] = recorder.phases.compactMap {
            if case .running(let done, let total) = $0 {
                #expect(total == 4)
                return done
            }
            return nil
        }
        #expect(counts.first == 0)
        #expect(zip(counts, counts.dropFirst()).allSatisfy { $1 == $0 + 1 })
        #expect(counts.allSatisfy { $0 <= 4 })
    }

    @Test("Only the files still unencrypted are counted and encrypted")
    func skipsAlreadyEncryptedFiles() async {
        let files = [
            FakeLeftoverStore.file("a.jpg", encrypted: true),
            FakeLeftoverStore.file("b.pdf", encrypted: false),
            FakeLeftoverStore.file("c.mov", encrypted: true),
        ]
        let harness = MigrationHarness(files: files)
        let recorder = harness.recorder()
        await harness.run()
        await recorder.wait { $0 == .completed(fully: true) }
        await recorder.finish()
        #expect(harness.log.events(withPrefix: "enc:") == ["enc:b.pdf"])
        #expect(recorder.phases.first == .running(done: 0, total: 1))
    }

    @Test("With nothing to encrypt the phase is completed(fully: true) at once")
    func nothingToEncrypt() async {
        let harness = MigrationHarness(files: [FakeLeftoverStore.file("a.jpg", encrypted: true)])
        let recorder = harness.recorder()
        await harness.run()
        await recorder.finish()
        #expect(harness.migrator.phase == .completed(fully: true))
        #expect(recorder.phases == [.completed(fully: true)])
        #expect(harness.log.events(withPrefix: "enc:").isEmpty)
        #expect(harness.log.count(of: "finishEncryption") == 1)
    }

    @Test("An empty encrypted vault completes at once")
    func emptyVault() async {
        let harness = MigrationHarness(files: [])
        await harness.run()
        #expect(harness.migrator.phase == .completed(fully: true))
    }

    @Test("A store that is not encrypted is left alone and the phase stays idle")
    func nonEncryptedStoreDoesNothing() async {
        let harness = MigrationHarness(storeIsEncrypted: false)
        await harness.run()
        #expect(harness.migrator.phase == .idle)
        #expect(harness.log.events.isEmpty)
        #expect(harness.store.isEncrypted("a.jpg") == false)
    }

    @Test("A second call while a run is going does nothing: one runner")
    func secondCallWhileRunningDoesNothing() async {
        let harness = MigrationHarness()
        harness.gate.arm(at: "migrate:b.pdf")
        let first = Task { await harness.run() }
        #expect(await waitForCondition { harness.gate.hasReached("migrate:b.pdf") })
        await harness.run()
        harness.gate.release()
        await first.value
        #expect(harness.log.count(of: "list") == 1)
        #expect(harness.log.events(withPrefix: "enc:").count == 4)
        #expect(harness.log.count(of: "finishEncryption") == 1)
        #expect(harness.migrator.phase == .completed(fully: true))
    }

    @Test("A second call while the run is failed does nothing")
    func secondCallWhileFailedDoesNothing() async {
        let harness = MigrationHarness()
        harness.store.setFailure(.io("bad"), for: "c.mov")
        await harness.run()
        await harness.run()
        #expect(harness.log.count(of: "list") == 1)
        #expect(harness.migrator.phase == .failed(names: ["c.mov"]))
    }

    @Test("A second call while the run awaits the unreadable-trash choice does nothing")
    func secondCallWhileUnreadableTrashDoesNothing() async {
        let harness = MigrationHarness()
        harness.store.setFailure(.io("bad"), for: "c.mov")
        harness.store.unreadableTrash = true
        await harness.run()
        await harness.run()
        #expect(harness.log.count(of: "list") == 1)
        #expect(harness.migrator.phase == .unreadableTrash)
    }

    @Test("Every phase change is published once and the phase property ends on the last one")
    func eachChangePublishedOnce() async {
        let harness = MigrationHarness()
        let recorder = harness.recorder()
        await harness.run()
        await recorder.wait { $0 == .completed(fully: true) }
        await recorder.finish()
        #expect(zip(recorder.phases, recorder.phases.dropFirst()).allSatisfy { $0 != $1 })
        #expect(recorder.phases.last == harness.migrator.phase)
    }
}
