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
        let viewModel = makeViewModel(item)
        await viewModel.load()
        return (viewModel, item)
    }

    private func attributes(_ font: UIFont = .systemFont(ofSize: 12)) -> [NSAttributedString.Key: Any] {
        [.font: font]
    }

    /// A view model whose text is `Hello` in `font`, fully selected. (Formatting needs no load.)
    private func makeFormattingViewModel(
        font: UIFont = .systemFont(ofSize: 12), selecting: Bool = true
    ) -> TextEditorViewModel {
        let viewModel = makeViewModel(ViewerTestSupport.makeItem("Doc.rtf"))
        viewModel.textDidChange(NSAttributedString(string: "Hello", attributes: attributes(font)))
        viewModel.typingAttributes = attributes(font)
        viewModel.selectedRange = selecting ? NSRange(location: 0, length: 5) : NSRange(location: 5, length: 0)
        return viewModel
    }

    private func font(of viewModel: TextEditorViewModel, at index: Int = 0) -> UIFont? {
        viewModel.attributedText.attribute(.font, at: index, effectiveRange: nil) as? UIFont
    }

    private func typingFont(of viewModel: TextEditorViewModel) -> UIFont? {
        viewModel.typingAttributes[.font] as? UIFont
    }

    // MARK: - Loading

    @Test("Loading an RTF file shows its text")
    func loadsRTF() async throws {
        let (viewModel, item) = try await makeLoadedViewModel()
        defer { cleanUp(item) }
        #expect(viewModel.attributedText.string == "Hello")
        #expect(!viewModel.isReadOnly)
        #expect(alerts.alerts.isEmpty)
    }

    @Test("Empty data loads as empty text")
    func emptyDataLoadsEmpty() async throws {
        let item = try await makeStoredDocument(containing: Data())
        defer { cleanUp(item) }
        let viewModel = makeViewModel(item)
        await viewModel.load()
        #expect(viewModel.attributedText.string.isEmpty)
        #expect(!viewModel.isReadOnly)
        #expect(alerts.alerts.isEmpty)
    }

    @Test("A load failure shows an error and makes the editor read-only")
    func loadFailureReadOnly() async {
        let viewModel = makeViewModel(ViewerTestSupport.makeItem("Missing.rtf"))
        await viewModel.load()
        #expect(viewModel.isReadOnly)
        #expect(alerts.alerts.count == 1)
        if case .error = alerts.alerts.first {} else { Issue.record("expected an error alert") }
    }

    @Test("After a load failure no save ever runs")
    func loadFailureNeverSaves() async {
        let viewModel = makeViewModel(ViewerTestSupport.makeItem("Missing.rtf"))
        await viewModel.load()
        viewModel.textDidChange(NSAttributedString(string: "typed anyway"))
        sleeper.advance()
        await viewModel.done()
        await viewModel.viewDidDisappear()
        await ViewerTestSupport.settle()
        #expect(writeCount == 0)
        #expect(sleeper.requestedDurations.isEmpty)
    }

    @Test(
        "Non-empty data that does not start with {\\rtf is a load failure",
        arguments: ["plain text, not rich text", "{\"a\": 1}", "{ braces but not rtf }"])
    func nonRTFDataIsLoadFailure(text: String) async throws {
        let item = try await makeStoredDocument(containing: Data(text.utf8))
        defer { cleanUp(item) }
        let viewModel = makeViewModel(item)
        await viewModel.load()
        #expect(viewModel.isReadOnly)
        #expect(alerts.alerts.count == 1)
        if case .error = alerts.alerts.first {} else { Issue.record("expected an error alert") }
    }

    @Test("After a non-RTF load failure a change, Done and disappear write nothing")
    func nonRTFLoadFailureNeverSaves() async throws {
        let item = try await makeStoredDocument(containing: Data("{\"a\": 1}".utf8))
        defer { cleanUp(item) }
        let viewModel = makeViewModel(item)
        await viewModel.load()
        viewModel.textDidChange(NSAttributedString(string: "typed anyway"))
        sleeper.advance()
        await viewModel.done()
        await viewModel.viewDidDisappear()
        await ViewerTestSupport.settle()
        #expect(writeCount == 0)
        #expect(sleeper.requestedDurations.isEmpty)
    }

    @Test("Valid RTF data still loads after the RTF check")
    func validRTFStillLoads() async throws {
        let item = try await makeStoredDocument(containing: rtf("Valid"))
        defer { cleanUp(item) }
        let viewModel = makeViewModel(item)
        await viewModel.load()
        #expect(viewModel.attributedText.string == "Valid")
        #expect(!viewModel.isReadOnly)
        #expect(alerts.alerts.isEmpty)
    }

    // MARK: - Autosave

    @Test("A change saves 1 second after it")
    func autosaveAfterOneSecond() async throws {
        let (viewModel, item) = try await makeLoadedViewModel()
        defer { cleanUp(item) }
        viewModel.textDidChange(NSAttributedString(string: "Hello!"))
        await ViewerTestSupport.waitUntil { sleeper.pendingCount == 1 }
        #expect(sleeper.requestedDurations == [.seconds(1)])
        #expect(writeCount == 0)
        sleeper.advance()
        await ViewerTestSupport.waitUntil { writeCount == 1 }
        #expect(store.calls.contains(.write(item.id)))
    }

    @Test("A further change resets the delay so only one save happens")
    func furtherChangeResetsDelay() async throws {
        let (viewModel, item) = try await makeLoadedViewModel()
        defer { cleanUp(item) }
        viewModel.textDidChange(NSAttributedString(string: "Hello!"))
        await ViewerTestSupport.waitUntil { sleeper.pendingCount == 1 }
        viewModel.textDidChange(NSAttributedString(string: "Hello!!"))
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
        let (viewModel, item) = try await makeLoadedViewModel()
        defer { cleanUp(item) }
        viewModel.textDidChange(NSAttributedString(string: "Changed"))
        await viewModel.viewDidDisappear()
        #expect(writeCount == 1)
        #expect(store.calls.contains(.write(item.id)))
    }

    @Test("Done saves once, and the later disappear does not save again")
    func doneSavesOnce() async throws {
        let (viewModel, item) = try await makeLoadedViewModel()
        defer { cleanUp(item) }
        viewModel.textDidChange(NSAttributedString(string: "Changed"))
        await viewModel.done()
        await viewModel.viewDidDisappear()
        #expect(writeCount == 1)
    }

    @Test("Done cancels the pending autosave so it adds no second save")
    func doneCancelsAutosave() async throws {
        let (viewModel, item) = try await makeLoadedViewModel()
        defer { cleanUp(item) }
        viewModel.textDidChange(NSAttributedString(string: "Changed"))
        await ViewerTestSupport.waitUntil { sleeper.pendingCount == 1 }
        await viewModel.done()
        sleeper.advance()
        await ViewerTestSupport.settle()
        #expect(writeCount == 1)
    }

    @Test("Done asks the screen to dismiss")
    func doneDismisses() async throws {
        let (viewModel, item) = try await makeLoadedViewModel()
        defer { cleanUp(item) }
        let counter = DismissCounter()
        viewModel.onDismiss = { counter.count += 1 }
        viewModel.textDidChange(NSAttributedString(string: "Changed"))
        await viewModel.done()
        #expect(counter.count == 1)
    }

    @Test("A failed save on Done shows the error and keeps the editor open")
    func failedDoneKeepsEditorOpen() async throws {
        let (viewModel, item) = try await makeLoadedViewModel()
        defer { cleanUp(item) }
        let counter = DismissCounter()
        viewModel.onDismiss = { counter.count += 1 }
        viewModel.textDidChange(NSAttributedString(string: "Changed"))
        store.errorToThrow = .io("Disk full")
        await viewModel.done()
        #expect(alerts.alerts.count == 1)
        if case .error = alerts.alerts.first {} else { Issue.record("expected an error alert") }
        #expect(counter.count < 1)
    }

    @Test("A later successful Done after a failed one writes and dismisses")
    func doneSucceedsAfterFailure() async throws {
        let (viewModel, item) = try await makeLoadedViewModel()
        defer { cleanUp(item) }
        let counter = DismissCounter()
        viewModel.onDismiss = { counter.count += 1 }
        viewModel.textDidChange(NSAttributedString(string: "Changed"))
        store.errorToThrow = .io("Disk full")
        await viewModel.done()
        store.errorToThrow = nil
        await viewModel.done()
        #expect(store.calls.contains(.write(item.id)))
        #expect(counter.count == 1)
    }

    @Test("Done writes even with no change")
    func doneSavesWithoutChange() async throws {
        let (viewModel, item) = try await makeLoadedViewModel()
        defer { cleanUp(item) }
        let counter = DismissCounter()
        viewModel.onDismiss = { counter.count += 1 }
        await viewModel.done()
        #expect(writeCount == 1)
        #expect(counter.count == 1)
    }

    @Test("Disappearing writes even with no change")
    func disappearSavesWithoutChange() async throws {
        let (viewModel, item) = try await makeLoadedViewModel()
        defer { cleanUp(item) }
        await viewModel.viewDidDisappear()
        #expect(writeCount == 1)
    }

    @Test("Loading without a change schedules no autosave")
    func loadSchedulesNoAutosave() async throws {
        let (_, item) = try await makeLoadedViewModel()
        defer { cleanUp(item) }
        await ViewerTestSupport.settle()
        #expect(sleeper.requestedDurations.isEmpty)
        #expect(sleeper.pendingCount == 0)
    }

    // MARK: - Save failure

    @Test("A save failure shows an error")
    func saveFailureShowsError() async throws {
        let (viewModel, item) = try await makeLoadedViewModel()
        defer { cleanUp(item) }
        viewModel.textDidChange(NSAttributedString(string: "Changed"))
        store.errorToThrow = .io("Disk full")
        await viewModel.viewDidDisappear()
        #expect(alerts.alerts.count == 1)
        if case .error = alerts.alerts.first {} else { Issue.record("expected an error alert") }
    }

    @Test("A failed autosave shows an error")
    func autosaveFailureShowsError() async throws {
        let (viewModel, item) = try await makeLoadedViewModel()
        defer { cleanUp(item) }
        viewModel.textDidChange(NSAttributedString(string: "Changed"))
        await ViewerTestSupport.waitUntil { sleeper.pendingCount == 1 }
        store.errorToThrow = .io("Disk full")
        sleeper.advance()
        await ViewerTestSupport.waitUntil { !alerts.alerts.isEmpty }
        #expect(alerts.alerts.count == 1)
    }

    // MARK: - Formatting

    @Test("Bold applies to the selection and the typing attributes")
    func boldApplies() {
        let viewModel = makeFormattingViewModel()
        viewModel.toggleBold()
        #expect(font(of: viewModel)?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
        #expect(font(of: viewModel, at: 4)?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
        #expect(typingFont(of: viewModel)?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
    }

    @Test("Toggling bold twice removes it")
    func boldToggles() {
        let viewModel = makeFormattingViewModel()
        viewModel.toggleBold()
        viewModel.toggleBold()
        #expect(font(of: viewModel)?.fontDescriptor.symbolicTraits.contains(.traitBold) == false)
        #expect(typingFont(of: viewModel)?.fontDescriptor.symbolicTraits.contains(.traitBold) == false)
    }

    @Test("Italic applies and toggles off")
    func italicToggles() {
        let viewModel = makeFormattingViewModel()
        viewModel.toggleItalic()
        #expect(font(of: viewModel)?.fontDescriptor.symbolicTraits.contains(.traitItalic) == true)
        #expect(typingFont(of: viewModel)?.fontDescriptor.symbolicTraits.contains(.traitItalic) == true)
        viewModel.toggleItalic()
        #expect(font(of: viewModel)?.fontDescriptor.symbolicTraits.contains(.traitItalic) == false)
        #expect(typingFont(of: viewModel)?.fontDescriptor.symbolicTraits.contains(.traitItalic) == false)
    }

    @Test("Bold and italic combine")
    func boldAndItalicCombine() {
        let viewModel = makeFormattingViewModel()
        viewModel.toggleBold()
        viewModel.toggleItalic()
        let traits = font(of: viewModel)?.fontDescriptor.symbolicTraits
        #expect(traits?.contains(.traitBold) == true)
        #expect(traits?.contains(.traitItalic) == true)
    }

    @Test("Bold with no selection changes only the typing attributes")
    func boldWithoutSelection() {
        let viewModel = makeFormattingViewModel(selecting: false)
        viewModel.toggleBold()
        #expect(typingFont(of: viewModel)?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
        #expect(font(of: viewModel)?.fontDescriptor.symbolicTraits.contains(.traitBold) == false)
    }

    @Test("Underline toggles on and off")
    func underlineToggles() {
        let viewModel = makeFormattingViewModel()
        viewModel.toggleUnderline()
        let underlined = viewModel.attributedText.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int ?? 0
        let typingOn = viewModel.typingAttributes[.underlineStyle] as? Int ?? 0
        #expect(underlined != 0)
        #expect(typingOn != 0)
        viewModel.toggleUnderline()
        let off = viewModel.attributedText.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int ?? 0
        let typingOff = viewModel.typingAttributes[.underlineStyle] as? Int ?? 0
        #expect(off == 0)
        #expect(typingOff == 0)
    }

    @Test("Increasing the size adds 2 points")
    func increaseSize() {
        let viewModel = makeFormattingViewModel(font: .systemFont(ofSize: 12))
        viewModel.increaseFontSize()
        #expect(font(of: viewModel)?.pointSize == 14)
        #expect(typingFont(of: viewModel)?.pointSize == 14)
    }

    @Test("Decreasing the size subtracts 2 points")
    func decreaseSize() {
        let viewModel = makeFormattingViewModel(font: .systemFont(ofSize: 12))
        viewModel.decreaseFontSize()
        #expect(font(of: viewModel)?.pointSize == 10)
        #expect(typingFont(of: viewModel)?.pointSize == 10)
    }

    @Test("The size never goes below 8")
    func sizeMinimum() {
        let viewModel = makeFormattingViewModel(font: .systemFont(ofSize: 9))
        viewModel.decreaseFontSize()
        #expect(font(of: viewModel)?.pointSize == 8)
        viewModel.decreaseFontSize()
        #expect(font(of: viewModel)?.pointSize == 8)
        #expect(typingFont(of: viewModel)?.pointSize == 8)
    }

    @Test("Size changes with no selection change only the typing attributes")
    func sizeWithoutSelection() {
        let viewModel = makeFormattingViewModel(font: .systemFont(ofSize: 12), selecting: false)
        viewModel.increaseFontSize()
        #expect(typingFont(of: viewModel)?.pointSize == 14)
        #expect(font(of: viewModel)?.pointSize == 12)
    }

    @Test(
        "Alignment applies to the selection and the typing attributes",
        arguments: [NSTextAlignment.left, .center, .right, .justified])
    func alignment(alignment: NSTextAlignment) {
        let viewModel = makeFormattingViewModel()
        viewModel.setAlignment(alignment)
        let styleAttribute = viewModel.attributedText.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
        let applied = styleAttribute as? NSParagraphStyle
        let typing = viewModel.typingAttributes[.paragraphStyle] as? NSParagraphStyle
        #expect(applied?.alignment == alignment)
        #expect(typing?.alignment == alignment)
    }

    @Test("Alignment with no selection changes only the typing attributes")
    func alignmentWithoutSelection() {
        let viewModel = makeFormattingViewModel(selecting: false)
        viewModel.setAlignment(.center)
        let typing = viewModel.typingAttributes[.paragraphStyle] as? NSParagraphStyle
        #expect(typing?.alignment == .center)
        let styleAttribute = viewModel.attributedText.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
        let applied = styleAttribute as? NSParagraphStyle
        #expect(applied?.alignment != .center)
    }
}

@MainActor
final class DismissCounter {
    var count = 0
}
