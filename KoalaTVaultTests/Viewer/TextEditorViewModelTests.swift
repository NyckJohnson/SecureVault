import Foundation
import Testing
import UIKit

@testable import KoalaTVault

@MainActor
@Suite(.serialized) struct TextEditorViewModelTests {
    private let store = MockVaultStoring(withSampleContent: false)
    private let alerts = MockAlertPresenting()
    private let sleeper = ViewerManualSleeper()

    private func makeViewModel(_ item: VaultItem) -> TextEditorViewModel {
        let sleeper = self.sleeper
        return TextEditorViewModel(item: item, store: store, alerts: alerts, sleep: { try await sleeper.sleep($0) })
    }

    /// A stored .rtf item whose disk file holds `data`. Remove the file with `cleanUp`.
    private func makeStoredDocument(containing data: Data) async throws -> VaultItem {
        let item = try await store.addFile(
            from: URL(fileURLWithPath: "/tmp/ViewerTestsSource"), named: "\(UUID().uuidString).rtf", to: store.root)
        try FileManager.default.createDirectory(
            at: item.diskURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: item.diskURL)
        return item
    }

    private func cleanUp(_ item: VaultItem) {
        try? FileManager.default.removeItem(at: item.diskURL)
    }

    private func rtf(_ text: String) throws -> Data {
        let attributed = NSAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: 12)])
        return try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    private var writeCount: Int {
        store.calls.filter { if case .write = $0 { true } else { false } }.count
    }

    /// A loaded, editable view model over a stored document.
    private func makeLoadedViewModel() async throws -> (TextEditorViewModel, VaultItem) {
        let item = try await makeStoredDocument(containing: rtf("Hello"))
        let vm = makeViewModel(item)
        await vm.load()
        return (vm, item)
    }

    private func attributes(_ font: UIFont = .systemFont(ofSize: 12)) -> [NSAttributedString.Key: Any] {
        [.font: font]
    }

    /// A view model whose text is `Hello` in `font`, fully selected. (Formatting needs no load.)
    private func makeFormattingViewModel(font: UIFont = .systemFont(ofSize: 12), selecting: Bool = true)
        -> TextEditorViewModel
    {
        let vm = makeViewModel(ViewerTestSupport.makeItem("Doc.rtf"))
        vm.textDidChange(NSAttributedString(string: "Hello", attributes: attributes(font)))
        vm.typingAttributes = attributes(font)
        vm.selectedRange = selecting ? NSRange(location: 0, length: 5) : NSRange(location: 5, length: 0)
        return vm
    }

    private func font(of vm: TextEditorViewModel, at index: Int = 0) -> UIFont? {
        vm.attributedText.attribute(.font, at: index, effectiveRange: nil) as? UIFont
    }

    private func typingFont(of vm: TextEditorViewModel) -> UIFont? {
        vm.typingAttributes[.font] as? UIFont
    }

    // MARK: - Loading

    @Test("Loading an RTF file shows its text")
    func loadsRTF() async throws {
        let (vm, item) = try await makeLoadedViewModel()
        defer { cleanUp(item) }
        #expect(vm.attributedText.string == "Hello")
        #expect(!vm.isReadOnly)
        #expect(alerts.alerts.isEmpty)
    }

    @Test("Empty data loads as empty text")
    func emptyDataLoadsEmpty() async throws {
        let item = try await makeStoredDocument(containing: Data())
        defer { cleanUp(item) }
        let vm = makeViewModel(item)
        await vm.load()
        #expect(vm.attributedText.string.isEmpty)
        #expect(!vm.isReadOnly)
        #expect(alerts.alerts.isEmpty)
    }

    @Test("A load failure shows an error and makes the editor read-only")
    func loadFailureReadOnly() async {
        let vm = makeViewModel(ViewerTestSupport.makeItem("Missing.rtf"))
        await vm.load()
        #expect(vm.isReadOnly)
        #expect(alerts.alerts.count == 1)
        if case .error = alerts.alerts.first {} else { Issue.record("expected an error alert") }
    }

    @Test("After a load failure no save ever runs")
    func loadFailureNeverSaves() async {
        let vm = makeViewModel(ViewerTestSupport.makeItem("Missing.rtf"))
        await vm.load()
        vm.textDidChange(NSAttributedString(string: "typed anyway"))
        sleeper.advance()
        await vm.done()
        await vm.viewDidDisappear()
        await ViewerTestSupport.settle()
        #expect(writeCount == 0)
        #expect(sleeper.requestedDurations.isEmpty)
    }

    // MARK: - Autosave

    @Test("A change saves 1 second after it")
    func autosaveAfterOneSecond() async throws {
        let (vm, item) = try await makeLoadedViewModel()
        defer { cleanUp(item) }
        vm.textDidChange(NSAttributedString(string: "Hello!"))
        await ViewerTestSupport.waitUntil { sleeper.pendingCount == 1 }
        #expect(sleeper.requestedDurations == [.seconds(1)])
        #expect(writeCount == 0)
        sleeper.advance()
        await ViewerTestSupport.waitUntil { writeCount == 1 }
        #expect(store.calls.contains(.write(item.id)))
    }

    @Test("A further change resets the delay so only one save happens")
    func furtherChangeResetsDelay() async throws {
        let (vm, item) = try await makeLoadedViewModel()
        defer { cleanUp(item) }
        vm.textDidChange(NSAttributedString(string: "Hello!"))
        await ViewerTestSupport.waitUntil { sleeper.pendingCount == 1 }
        vm.textDidChange(NSAttributedString(string: "Hello!!"))
        await ViewerTestSupport.waitUntil { sleeper.requestedDurations.count == 2 }
        #expect(sleeper.pendingCount == 1)
        #expect(writeCount == 0)
        sleeper.advance()
        await ViewerTestSupport.waitUntil { writeCount == 1 }
        await ViewerTestSupport.settle()
        #expect(writeCount == 1)
    }

    @Test("Without a change nothing is autosaved")
    func noChangeNoAutosave() async throws {
        let (_, item) = try await makeLoadedViewModel()
        defer { cleanUp(item) }
        await ViewerTestSupport.settle()
        sleeper.advance()
        await ViewerTestSupport.settle()
        #expect(writeCount == 0)
    }

    // MARK: - Disappear and Done

    @Test("Disappearing saves the pending change")
    func saveOnDisappear() async throws {
        let (vm, item) = try await makeLoadedViewModel()
        defer { cleanUp(item) }
        vm.textDidChange(NSAttributedString(string: "Changed"))
        await vm.viewDidDisappear()
        #expect(writeCount == 1)
        #expect(store.calls.contains(.write(item.id)))
    }

    @Test("Done saves once, and the later disappear does not save again")
    func doneSavesOnce() async throws {
        let (vm, item) = try await makeLoadedViewModel()
        defer { cleanUp(item) }
        vm.textDidChange(NSAttributedString(string: "Changed"))
        await vm.done()
        await vm.viewDidDisappear()
        #expect(writeCount == 1)
    }

    @Test("Done cancels the pending autosave so it adds no second save")
    func doneCancelsAutosave() async throws {
        let (vm, item) = try await makeLoadedViewModel()
        defer { cleanUp(item) }
        vm.textDidChange(NSAttributedString(string: "Changed"))
        await ViewerTestSupport.waitUntil { sleeper.pendingCount == 1 }
        await vm.done()
        sleeper.advance()
        await ViewerTestSupport.settle()
        #expect(writeCount == 1)
    }

    @Test("Done asks the screen to dismiss")
    func doneDismisses() async throws {
        let (vm, item) = try await makeLoadedViewModel()
        defer { cleanUp(item) }
        let counter = DismissCounter()
        vm.onDismiss = { counter.count += 1 }
        vm.textDidChange(NSAttributedString(string: "Changed"))
        await vm.done()
        #expect(counter.count == 1)
    }

    // MARK: - Save failure

    @Test("A save failure shows an error")
    func saveFailureShowsError() async throws {
        let (vm, item) = try await makeLoadedViewModel()
        defer { cleanUp(item) }
        vm.textDidChange(NSAttributedString(string: "Changed"))
        store.errorToThrow = .io("Disk full")
        await vm.viewDidDisappear()
        #expect(alerts.alerts.count == 1)
        if case .error = alerts.alerts.first {} else { Issue.record("expected an error alert") }
    }

    @Test("A failed autosave shows an error")
    func autosaveFailureShowsError() async throws {
        let (vm, item) = try await makeLoadedViewModel()
        defer { cleanUp(item) }
        vm.textDidChange(NSAttributedString(string: "Changed"))
        await ViewerTestSupport.waitUntil { sleeper.pendingCount == 1 }
        store.errorToThrow = .io("Disk full")
        sleeper.advance()
        await ViewerTestSupport.waitUntil { !alerts.alerts.isEmpty }
        #expect(alerts.alerts.count == 1)
    }

    // MARK: - Formatting

    @Test("Bold applies to the selection and the typing attributes")
    func boldApplies() {
        let vm = makeFormattingViewModel()
        vm.toggleBold()
        #expect(font(of: vm)?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
        #expect(font(of: vm, at: 4)?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
        #expect(typingFont(of: vm)?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
    }

    @Test("Toggling bold twice removes it")
    func boldToggles() {
        let vm = makeFormattingViewModel()
        vm.toggleBold()
        vm.toggleBold()
        #expect(font(of: vm)?.fontDescriptor.symbolicTraits.contains(.traitBold) == false)
        #expect(typingFont(of: vm)?.fontDescriptor.symbolicTraits.contains(.traitBold) == false)
    }

    @Test("Italic applies and toggles off")
    func italicToggles() {
        let vm = makeFormattingViewModel()
        vm.toggleItalic()
        #expect(font(of: vm)?.fontDescriptor.symbolicTraits.contains(.traitItalic) == true)
        #expect(typingFont(of: vm)?.fontDescriptor.symbolicTraits.contains(.traitItalic) == true)
        vm.toggleItalic()
        #expect(font(of: vm)?.fontDescriptor.symbolicTraits.contains(.traitItalic) == false)
        #expect(typingFont(of: vm)?.fontDescriptor.symbolicTraits.contains(.traitItalic) == false)
    }

    @Test("Bold and italic combine")
    func boldAndItalicCombine() {
        let vm = makeFormattingViewModel()
        vm.toggleBold()
        vm.toggleItalic()
        let traits = font(of: vm)?.fontDescriptor.symbolicTraits
        #expect(traits?.contains(.traitBold) == true)
        #expect(traits?.contains(.traitItalic) == true)
    }

    @Test("Bold with no selection changes only the typing attributes")
    func boldWithoutSelection() {
        let vm = makeFormattingViewModel(selecting: false)
        vm.toggleBold()
        #expect(typingFont(of: vm)?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
        #expect(font(of: vm)?.fontDescriptor.symbolicTraits.contains(.traitBold) == false)
    }

    @Test("Underline toggles on and off")
    func underlineToggles() {
        let vm = makeFormattingViewModel()
        vm.toggleUnderline()
        let on = vm.attributedText.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int ?? 0
        let typingOn = vm.typingAttributes[.underlineStyle] as? Int ?? 0
        #expect(on != 0)
        #expect(typingOn != 0)
        vm.toggleUnderline()
        let off = vm.attributedText.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int ?? 0
        let typingOff = vm.typingAttributes[.underlineStyle] as? Int ?? 0
        #expect(off == 0)
        #expect(typingOff == 0)
    }

    @Test("Increasing the size adds 2 points")
    func increaseSize() {
        let vm = makeFormattingViewModel(font: .systemFont(ofSize: 12))
        vm.increaseFontSize()
        #expect(font(of: vm)?.pointSize == 14)
        #expect(typingFont(of: vm)?.pointSize == 14)
    }

    @Test("Decreasing the size subtracts 2 points")
    func decreaseSize() {
        let vm = makeFormattingViewModel(font: .systemFont(ofSize: 12))
        vm.decreaseFontSize()
        #expect(font(of: vm)?.pointSize == 10)
        #expect(typingFont(of: vm)?.pointSize == 10)
    }

    @Test("The size never goes below 8")
    func sizeMinimum() {
        let vm = makeFormattingViewModel(font: .systemFont(ofSize: 9))
        vm.decreaseFontSize()
        #expect(font(of: vm)?.pointSize == 8)
        vm.decreaseFontSize()
        #expect(font(of: vm)?.pointSize == 8)
        #expect(typingFont(of: vm)?.pointSize == 8)
    }

    @Test("Size changes with no selection change only the typing attributes")
    func sizeWithoutSelection() {
        let vm = makeFormattingViewModel(font: .systemFont(ofSize: 12), selecting: false)
        vm.increaseFontSize()
        #expect(typingFont(of: vm)?.pointSize == 14)
        #expect(font(of: vm)?.pointSize == 12)
    }

    @Test(
        "Alignment applies to the selection and the typing attributes",
        arguments: [NSTextAlignment.left, .center, .right, .justified])
    func alignment(alignment: NSTextAlignment) {
        let vm = makeFormattingViewModel()
        vm.setAlignment(alignment)
        let applied = vm.attributedText.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let typing = vm.typingAttributes[.paragraphStyle] as? NSParagraphStyle
        #expect(applied?.alignment == alignment)
        #expect(typing?.alignment == alignment)
    }

    @Test("Alignment with no selection changes only the typing attributes")
    func alignmentWithoutSelection() {
        let vm = makeFormattingViewModel(selecting: false)
        vm.setAlignment(.center)
        let typing = vm.typingAttributes[.paragraphStyle] as? NSParagraphStyle
        #expect(typing?.alignment == .center)
        let applied = vm.attributedText.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(applied?.alignment != .center)
    }
}

@MainActor
final class DismissCounter {
    var count = 0
}
