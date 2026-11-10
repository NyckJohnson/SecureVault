import Foundation
import Testing

@testable import KoalaTVault

// API under test (chosen by the test-writer; the code-writer implements it):
//
// @MainActor final class FolderPickerViewModel {
//     init(store: VaultStoring, preferences: PreferencesStoring, excluding: [VaultItem],
//          alerts: AlertPresenting, directory: VaultDirectory? = nil)   // nil = the vault root
//     // folders are listed with the saved sort option and direction (preferences.sortOption/sortDirection)
//     let directory: VaultDirectory                    // the current folder
//     private(set) var folders: [VaultItem]            // subfolders of `directory` only
//     func load() async
//     func moveHereDestination() -> VaultDirectory     // the "Move Here" choice
// }

@MainActor
@Suite struct FolderPickerViewModelTests {
    private func makeModel(
        store: MockVaultStoring, excluding: [VaultItem], alerts: MockAlertPresenting,
        directory: VaultDirectory? = nil
    ) -> FolderPickerViewModel {
        FolderPickerViewModel(
            store: store, preferences: MockPreferencesStoring(), excluding: excluding, alerts: alerts,
            directory: directory)
    }

    private func errorMessages(_ alerts: MockAlertPresenting) -> [String] {
        alerts.alerts.compactMap { alert in
            if case .error(let message) = alert { return message }
            return nil
        }
    }

    @Test("The picker starts at the vault root")
    func startsAtRoot() {
        let store = MockVaultStoring()
        let model = makeModel(store: store, excluding: [], alerts: MockAlertPresenting())
        #expect(model.directory == store.root)
    }

    @Test("Load lists only the current folder's subfolders, not files")
    func listsSubfoldersOnly() async {
        let store = MockVaultStoring()
        let model = makeModel(store: store, excluding: [], alerts: MockAlertPresenting())
        await model.load()
        #expect(model.folders.map(\.name) == ["Documents", "Photos"])
        #expect(model.folders.allSatisfy { $0.isDirectory })
    }

    @Test("Load lists the subfolders of a nested folder")
    func listsNestedSubfolders() async throws {
        let store = MockVaultStoring()
        let photos = try #require(store.allItems.first { $0.name == "Photos" }?.asDirectory)
        _ = try await store.createFolder(named: "Summer", in: photos)
        let model = makeModel(store: store, excluding: [], alerts: MockAlertPresenting(), directory: photos)
        await model.load()
        #expect(model.folders.map(\.name) == ["Summer"])
    }

    @Test("A folder with no subfolders lists none")
    func emptyFolderListsNone() async throws {
        let store = MockVaultStoring()
        let photos = try #require(store.allItems.first { $0.name == "Photos" }?.asDirectory)
        let model = makeModel(store: store, excluding: [], alerts: MockAlertPresenting(), directory: photos)
        await model.load()
        #expect(model.folders.isEmpty)
    }

    @Test("Folders being moved are left out of the list")
    func excludesMovedFolders() async throws {
        let store = MockVaultStoring()
        let photos = try #require(store.allItems.first { $0.name == "Photos" })
        let model = makeModel(store: store, excluding: [photos], alerts: MockAlertPresenting())
        await model.load()
        #expect(model.folders.map(\.name) == ["Documents"])
    }

    @Test("Moved files do not affect the list of folders")
    func excludingFilesChangesNothing() async throws {
        let store = MockVaultStoring()
        let beach = try #require(store.allItems.first { $0.name == "Beach.jpg" })
        let model = makeModel(store: store, excluding: [beach], alerts: MockAlertPresenting())
        await model.load()
        #expect(model.folders.map(\.name) == ["Documents", "Photos"])
    }

    @Test("A moved folder's subfolders are unreachable because the folder itself is not listed")
    func excludedFolderHidesItsSubfolders() async throws {
        let store = MockVaultStoring()
        let photos = try #require(store.allItems.first { $0.name == "Photos" })
        _ = try await store.createFolder(named: "Summer", in: try #require(photos.asDirectory))
        let model = makeModel(store: store, excluding: [photos], alerts: MockAlertPresenting())
        await model.load()
        #expect(!model.folders.map(\.name).contains("Photos"))
        #expect(!model.folders.map(\.name).contains("Summer"))
    }

    @Test("Move Here returns the current folder")
    func moveHereReturnsCurrentFolder() async throws {
        let store = MockVaultStoring()
        let photos = try #require(store.allItems.first { $0.name == "Photos" }?.asDirectory)
        let atRoot = makeModel(store: store, excluding: [], alerts: MockAlertPresenting())
        let nested = makeModel(store: store, excluding: [], alerts: MockAlertPresenting(), directory: photos)
        #expect(atRoot.moveHereDestination() == store.root)
        #expect(nested.moveHereDestination() == photos)
    }

    @Test("A load error is shown to the user")
    func loadErrorShown() async {
        let store = MockVaultStoring()
        store.errorToThrow = .io("boom")
        let alerts = MockAlertPresenting()
        let model = makeModel(store: store, excluding: [], alerts: alerts)
        await model.load()
        #expect(errorMessages(alerts) == ["boom"])
        #expect(model.folders.isEmpty)
    }

    @Test("A successful load shows no alert")
    func loadSuccessNoAlert() async {
        let alerts = MockAlertPresenting()
        let model = makeModel(store: MockVaultStoring(), excluding: [], alerts: alerts)
        await model.load()
        #expect(alerts.alerts.isEmpty)
    }

    @Test("Folders are listed with the saved sort option and direction")
    func listsWithSavedSort() async {
        let store = MockVaultStoring()
        let preferences = MockPreferencesStoring(sortOption: .dateModified, sortDirection: .descending)
        let model = FolderPickerViewModel(
            store: store, preferences: preferences, excluding: [], alerts: MockAlertPresenting())
        await model.load()
        #expect(store.calls.contains(.contents(directory: "", .dateModified, .descending)))
        #expect(model.folders.map(\.name) == ["Photos", "Documents"])
    }

    @Test("Folders are listed oldest first when the saved sort is date modified ascending")
    func listsWithSavedSortAscending() async {
        let store = MockVaultStoring()
        let preferences = MockPreferencesStoring(sortOption: .dateModified, sortDirection: .ascending)
        let model = FolderPickerViewModel(
            store: store, preferences: preferences, excluding: [], alerts: MockAlertPresenting())
        await model.load()
        #expect(store.calls.contains(.contents(directory: "", .dateModified, .ascending)))
        #expect(model.folders.map(\.name) == ["Documents", "Photos"])
    }

    @Test("A name-descending saved sort reverses the folder order")
    func listsNameDescending() async {
        let store = MockVaultStoring()
        let preferences = MockPreferencesStoring(sortOption: .name, sortDirection: .descending)
        let model = FolderPickerViewModel(
            store: store, preferences: preferences, excluding: [], alerts: MockAlertPresenting())
        await model.load()
        #expect(model.folders.map(\.name) == ["Photos", "Documents"])
    }
}
