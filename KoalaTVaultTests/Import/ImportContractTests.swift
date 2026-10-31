import Foundation
import Testing

@testable import KoalaTVault

// Assumed: `ImportError` is a `LocalizedError` with the approved text (Import memo, "ImportError text").
@Suite struct ImportContractTests {
    @Test(
        "Each import error reads as its approved text",
        arguments: [
            (ImportError.unreadableSource("Trip"), "Couldn't read \"Trip\"."),
            (ImportError.fileLimitReached(limit: 100), "This vault has reached its limit of 100 files.")
        ])
    func errorText(error: ImportError, expected: String) {
        let thrown: any Error = error
        #expect(thrown.localizedDescription == expected)
        #expect((thrown as? any LocalizedError)?.errorDescription == expected)
    }

    @Test("The limit appears in the file-limit text")
    func limitAppearsInText() {
        let thrown: any Error = ImportError.fileLimitReached(limit: 7)
        #expect(thrown.localizedDescription == "This vault has reached its limit of 7 files.")
    }
}
