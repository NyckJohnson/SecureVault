import Foundation
import Testing

@testable import KoalaTVault

/// Pins down the results of `contents(of:sortedBy:_:)` so a faster listing must return exactly the same items.
@Suite struct LiveVaultStoreListingTests {
    private func resolved(_ url: URL) -> String { url.resolvingSymlinksInPath().path }

    private func lockMode(_ encrypted: Bool) -> LockMode { encrypted ? .password : .none }

    private func diskSize(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? -1
    }

    // MARK: - Fields

    @Test(
        "Every field of listed files and folders is right, at the root and in a nested folder",
        arguments: [false, true], [false, true])
    func fieldsOfListedItems(encrypted: Bool, nested: Bool) async throws {
        let vault = try VaultStoreFixture(lockMode: lockMode(encrypted))
        defer { vault.cleanUp() }
        let directory = nested ? try vault.folder("Docs") : vault.root
        let sub = try vault.folder("Sub", in: nested ? directory : nil)
        let report = try await vault.add("report.pdf", "twelve bytes", to: directory)
        let note = try await vault.add("note.txt", "abc", to: directory)
        let fileDate = Date(timeIntervalSince1970: 1_500_000_000)
        let folderDate = Date(timeIntervalSince1970: 1_550_000_000)
        try vault.setModified(report.diskURL, to: fileDate)
        try vault.setModified(note.diskURL, to: fileDate.addingTimeInterval(500))
        try vault.setModified(sub.diskURL, to: folderDate)

        let items = try await vault.list(directory)
        #expect(items.count == 3)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
        let prefix = nested ? "Docs/" : ""

        let reportItem = try #require(byName["report.pdf"])
        #expect(reportItem.id == report.id)
        if encrypted {
            #expect(reportItem.id.hasPrefix(prefix) && !reportItem.id.contains("report"))
        } else {
            #expect(reportItem.id == prefix + "report.pdf")
        }
        #expect(reportItem.isDirectory == false)
        #expect(reportItem.isEncrypted == encrypted)
        #expect(reportItem.fileSize == (try diskSize(report.diskURL)))
        #expect(encrypted || reportItem.fileSize == 12)
        #expect(abs(reportItem.dateModified.timeIntervalSince(fileDate)) < 1)
        #expect(resolved(reportItem.diskURL) == resolved(report.diskURL))
        #expect(resolved(reportItem.rootURL) == resolved(vault.rootURL))
        #expect(reportItem.deletedAt == nil)

        let noteItem = try #require(byName["note.txt"])
        #expect(noteItem.id == note.id)
        #expect(noteItem.fileSize == (try diskSize(note.diskURL)))
        #expect(abs(noteItem.dateModified.timeIntervalSince(fileDate.addingTimeInterval(500))) < 1)
        #expect(noteItem.isEncrypted == encrypted)

        let folderItem = try #require(byName["Sub"])
        #expect(folderItem.id == prefix + "Sub")
        #expect(folderItem.isDirectory)
        #expect(folderItem.fileSize == nil)
        #expect(folderItem.isEncrypted == false)
        #expect(abs(folderItem.dateModified.timeIntervalSince(folderDate)) < 1)
        #expect(resolved(folderItem.diskURL) == resolved(sub.diskURL))
        #expect(resolved(folderItem.rootURL) == resolved(vault.rootURL))
        #expect(folderItem.deletedAt == nil)
    }

    @Test("Listing twice gives identical items in an encrypted vault, root and nested", arguments: [false, true])
    func repeatedListingsAreIdentical(nested: Bool) async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let directory = nested ? try vault.folder("Docs") : vault.root
        try vault.folder("Sub", in: nested ? directory : nil)
        for name in ["b.txt", "a.pdf", "c.jpg"] { try await vault.add(name, "data", to: directory) }
        let first = try await vault.list(directory)
        let second = try await vault.list(directory)
        #expect(first == second)
        #expect(first.count == 4)
    }

    @Test("Hidden entries are excluded in both modes, in a nested folder too", arguments: [false, true])
    func hiddenExcludedNested(encrypted: Bool) async throws {
        let vault = try VaultStoreFixture(lockMode: lockMode(encrypted))
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        try await vault.add("shown.txt", to: docs)
        try vault.diskFile(".hidden", in: docs)
        try vault.folder(".hiddenFolder", in: docs)
        #expect(try await vault.names(docs) == ["shown.txt"])
    }

    @Test("A file the index maps but which is missing on disk is not listed", arguments: [false, true])
    func mappedButMissingFileIsNotListed(nested: Bool) async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let directory = nested ? try vault.folder("Docs") : vault.root
        let kept = try await vault.add("kept.txt", to: directory)
        let gone = try await vault.add("gone.txt", to: directory)
        try FileManager.default.removeItem(at: gone.diskURL)
        let items = try await vault.list(directory)
        #expect(items.map(\.name) == ["kept.txt"])
        #expect(items.map(\.id) == [kept.id])
    }

    @Test("A folder with an index but only unmapped plain entries shows their disk names")
    func unmappedEntriesWithIndexPresent() async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        let docs = try vault.folder("Docs")
        try await vault.add("mapped.txt", to: docs)
        try vault.diskFile("stray.md", "s", in: docs)
        #expect(try await vault.names(docs) == ["mapped.txt", "stray.md"])
        let stray = try #require(try await vault.list(docs).first { $0.name == "stray.md" })
        #expect(stray.isEncrypted == false)
        #expect(stray.id == "Docs/stray.md")
        #expect(stray.fileSize == 1)
    }

    // MARK: - Sorting

    @Test("Numeric-looking names sort by number, case-insensitively, and repeatably")
    func numericLookingNames() async throws {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { vault.cleanUp() }
        for name in ["file 10.txt", "file 2.txt", "file 1.txt", "File 3.txt", "file 20.txt"] {
            try vault.diskFile(name)
        }
        let ascending = try await vault.names(nil, .name, .ascending)
        #expect(ascending == ["file 1.txt", "file 2.txt", "File 3.txt", "file 10.txt", "file 20.txt"])
        let descending = try await vault.names(nil, .name, .descending)
        #expect(descending == ascending.reversed())
        #expect(try await vault.names(nil, .name, .ascending) == ascending)
    }

    @Test("Folders come first for every option and direction", arguments: SortOption.allCases, SortDirection.allCases)
    func foldersFirst(option: SortOption, direction: SortDirection) async throws {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { vault.cleanUp() }
        for (index, name) in ["a.txt", "b.pdf", "c.jpg", "d.txt"].enumerated() {
            let url = try vault.diskFile(name)
            try vault.setModified(url, to: Date(timeIntervalSince1970: 1_600_000_000 + Double(index) * 100))
        }
        for (index, name) in ["Y", "x", "Z"].enumerated() {
            let folder = try vault.folder(name)
            try vault.setModified(folder.diskURL, to: Date(timeIntervalSince1970: 1_700_000_000 - Double(index) * 100))
        }
        let items = try await vault.list(nil, option, direction)
        #expect(items.count == 7)
        #expect(items.prefix(3).allSatisfy { $0.isDirectory })
        #expect(items.suffix(4).allSatisfy { !$0.isDirectory })
    }

    @Test("Folders sort by name, date and type among themselves, both directions")
    func foldersSortAmongThemselves() async throws {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { vault.cleanUp() }
        let base = Date(timeIntervalSince1970: 1_600_000_000)
        for (name, offset) in [("beta", 300.0), ("Alpha", 100.0), ("gamma", 200.0)] {
            let folder = try vault.folder(name)
            try vault.setModified(folder.diskURL, to: base.addingTimeInterval(offset))
        }
        #expect(try await vault.names(nil, .name, .ascending) == ["Alpha", "beta", "gamma"])
        #expect(try await vault.names(nil, .name, .descending) == ["gamma", "beta", "Alpha"])
        #expect(try await vault.names(nil, .dateModified, .ascending) == ["Alpha", "gamma", "beta"])
        #expect(try await vault.names(nil, .dateModified, .descending) == ["beta", "gamma", "Alpha"])
        #expect(try await vault.names(nil, .type, .ascending) == ["Alpha", "beta", "gamma"])
    }

    @Test(
        "Equal sort keys list in the same order every time",
        arguments: SortOption.allCases, [false, true])
    func ties(option: SortOption, encrypted: Bool) async throws {
        let vault = try VaultStoreFixture(lockMode: lockMode(encrypted))
        defer { vault.cleanUp() }
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        for index in 0..<12 {
            let item = try await vault.add("same.txt", "\(index)")
            try vault.setModified(item.diskURL, to: date)
        }
        for index in 0..<4 {
            let folder = try vault.folder("tie\(index)")
            try vault.setModified(folder.diskURL, to: date)
        }
        for direction in SortDirection.allCases {
            let first = try await vault.list(nil, option, direction)
            let second = try await vault.list(nil, option, direction)
            let third = try await vault.list(nil, option, direction)
            #expect(first.count == 16)
            #expect(first.map(\.id) == second.map(\.id))
            #expect(second.map(\.id) == third.map(\.id))
            #expect(first.prefix(4).allSatisfy { $0.isDirectory })
        }
    }

    // MARK: - Larger folder

    private struct Entry {
        let diskName: String
        let displayName: String
        let isDirectory: Bool
        let date: Date
    }

    private func ext(_ entry: Entry) -> String { (entry.displayName as NSString).pathExtension.lowercased() }

    /// The order the spec asks for: folders first, then the option; name case-insensitive, type by extension then name.
    private func expectedOrder(_ entries: [Entry], _ option: SortOption, _ direction: SortDirection) -> [String] {
        func ascending(_ lhs: Entry, _ rhs: Entry) -> Bool {
            switch option {
            case .name:
                return lhs.displayName.lowercased() < rhs.displayName.lowercased()
            case .type:
                if ext(lhs) != ext(rhs) { return ext(lhs) < ext(rhs) }
                return lhs.displayName.lowercased() < rhs.displayName.lowercased()
            case .dateModified:
                return lhs.date < rhs.date
            }
        }
        func ordered(_ group: [Entry]) -> [Entry] {
            let upward = group.sorted(by: ascending)
            return direction == .ascending ? upward : upward.reversed()
        }
        let folders = entries.filter(\.isDirectory)
        let files = entries.filter { !$0.isDirectory }
        return (ordered(folders) + ordered(files)).map(\.displayName)
    }

    /// Deterministic generator, so every run builds the same folder.
    private struct Lcg {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    private func buildEntries() -> [Entry] {
        var rng = Lcg(state: 42)
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        let extensions = ["txt", "pdf", "jpg", "mp3", "png"]
        var seen = Set<String>()
        var seconds = Array(0..<500)
        for index in stride(from: seconds.count - 1, to: 0, by: -1) { seconds.swapAt(index, rng.next(index + 1)) }
        var entries: [Entry] = []
        while entries.count < 500 {
            let length = 4 + rng.next(6)
            var base = ""
            for _ in 0..<length {
                let letter = String(letters[rng.next(letters.count)])
                base += rng.next(2) == 0 ? letter : letter.uppercased()
            }
            let isDirectory = entries.count % 10 == 0
            let name = isDirectory ? base : base + "." + extensions[rng.next(extensions.count)]
            guard seen.insert(name.lowercased()).inserted else { continue }
            entries.append(
                Entry(
                    diskName: name, displayName: name, isDirectory: isDirectory,
                    date: Date(timeIntervalSince1970: 1_500_000_000 + Double(seconds[entries.count]) * 60)))
        }
        return entries
    }

    private func populate(_ vault: VaultStoreFixture, _ entries: [Entry]) throws {
        for entry in entries {
            let url: URL
            if entry.isDirectory {
                url = try vault.folder(entry.diskName).diskURL
            } else {
                url = try vault.diskFile(entry.diskName, entry.diskName)
            }
            try vault.setModified(url, to: entry.date)
        }
    }

    @Test(
        "A 500-entry plaintext folder lists in the order the sort rule gives",
        arguments: SortOption.allCases, SortDirection.allCases)
    func largePlaintextFolder(option: SortOption, direction: SortDirection) async throws {
        let vault = try VaultStoreFixture(lockMode: .none, keyLoaded: false)
        defer { vault.cleanUp() }
        let entries = buildEntries()
        try populate(vault, entries)
        let items = try await vault.list(nil, option, direction)
        #expect(items.count == 500)
        #expect(items.map(\.name) == expectedOrder(entries, option, direction))
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.displayName, $0) })
        for item in items {
            let entry = try #require(byName[item.name])
            #expect(item.isDirectory == entry.isDirectory)
            #expect(item.id == entry.diskName)
            #expect(abs(item.dateModified.timeIntervalSince(entry.date)) < 1)
            #expect(item.fileSize == (entry.isDirectory ? nil : entry.diskName.utf8.count))
        }
    }

    @Test(
        "A 500-entry encrypted folder lists by original names in the order the sort rule gives",
        arguments: SortOption.allCases, SortDirection.allCases)
    func largeEncryptedFolder(option: SortOption, direction: SortDirection) async throws {
        let vault = try VaultStoreFixture(lockMode: .password)
        defer { vault.cleanUp() }
        var entries = buildEntries()
        var index: [String: String] = [:]
        for position in entries.indices where !entries[position].isDirectory {
            let uuid = UUID().uuidString
            index[uuid] = entries[position].displayName
            entries[position] = Entry(
                diskName: uuid, displayName: entries[position].displayName, isDirectory: false,
                date: entries[position].date)
        }
        try populate(vault, entries)
        try vault.writeIndex(index, context: ".vault_map")
        let items = try await vault.list(nil, option, direction)
        #expect(items.count == 500)
        #expect(items.map(\.name) == expectedOrder(entries, option, direction))
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.displayName, $0) })
        for item in items {
            let entry = try #require(byName[item.name])
            #expect(item.id == entry.diskName)
            #expect(item.isEncrypted == !entry.isDirectory)
            #expect(item.isDirectory == entry.isDirectory)
        }
        let again = try await vault.list(nil, option, direction)
        #expect(again == items)
    }
}
