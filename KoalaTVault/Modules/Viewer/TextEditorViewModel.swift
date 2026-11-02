import Combine
import Foundation
import UIKit

/// The logic of the rich-text editor: loading, autosave and formatting.
///
/// The one rule that protects the document: nothing is ever written unless it loaded. Every save goes through
/// `save()`, which checks `isReadOnly`, and that only turns off after a successful load.
@MainActor
final class TextEditorViewModel: ObservableObject {
    @Published private(set) var attributedText = NSAttributedString()
    /// True until the document has loaded, and for good after a load failure.
    @Published private(set) var isReadOnly = true

    /// The screen's text view's selection.
    var selectedRange = NSRange(location: 0, length: 0)
    /// The screen's text view's typing attributes.
    var typingAttributes: [NSAttributedString.Key: Any] = [:]
    /// Asks the screen to go away, after Done.
    var onDismiss: (@MainActor () -> Void)?

    private let item: VaultItem
    private let store: any VaultStoring
    private weak var alerts: (any AlertPresenting)?
    private let sleep: @Sendable (Duration) async throws -> Void
    private var didStartLoading = false
    /// Set while Done is finishing (and after), so the disappear that follows doesn't save a second time.
    private var isFinishing = false
    private var autosaveTask: Task<Void, Never>?
    /// The latest save; each waits for the one before, so the newest content lands last.
    private var saveTask: Task<Void, Error>?

    /// - Parameters:
    ///   - alerts: shows load and save errors; held weakly, as it is normally the screen that owns this model.
    ///   - sleep: waits out the autosave delay.
    init(
        item: VaultItem, store: any VaultStoring, alerts: any AlertPresenting,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.item = item
        self.store = store
        self.alerts = alerts
        self.sleep = sleep
    }

    deinit {
        autosaveTask?.cancel()
    }

    // MARK: - Loading

    /// Loads the document and makes it editable, or shows the error and stays read-only.
    func load() async {
        guard !didStartLoading else { return }
        didStartLoading = true
        do {
            attributedText = try await Self.readDocument(item, from: store)
            isReadOnly = false
        } catch {
            alerts?.showError(error)
        }
    }

    /// The document's text, read off the main thread (`@concurrent`: decrypting, reading and parsing are slow).
    /// The decrypted copy is only needed for this read, so it is removed right away, whatever the outcome.
    @concurrent
    private nonisolated static func readDocument(
        _ item: VaultItem, from store: any VaultStoring
    ) async throws -> sending NSAttributedString {
        let url = try await store.open(item)
        defer {
            if item.isEncrypted { store.removeTemporary(url) }
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return NSAttributedString() }
        // The parser accepts any text starting with "{" and returns only part of it (`{"a": 1}`, `{}`), and
        // the editor rewrites what it loaded on close, so such a file would be silently destroyed.
        guard data.starts(with: Data(#"{\rtf"#.utf8)) else { throw TextEditorLoadError.notRTF }
        return try NSAttributedString(
            data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
    }

    // MARK: - Editing and saving

    /// Records the text view's new text and restarts the autosave delay.
    func textDidChange(_ text: NSAttributedString) {
        attributedText = text
        scheduleAutosave()
    }

    /// Saves (also with no change, as the editor always has), then dismisses. If the save fails the screen
    /// stays, so the error can be seen and the edits aren't lost; Done can be tried again.
    func done() async {
        autosaveTask?.cancel()
        guard !isFinishing else { return }
        isFinishing = true
        guard await save() else {
            isFinishing = false
            return
        }
        onDismiss?()
    }

    /// Saves (also with no change, as the editor always has), unless Done already did.
    func viewDidDisappear() async {
        autosaveTask?.cancel()
        guard !isFinishing else { return }
        await save()
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        guard !isReadOnly else { return }
        autosaveTask = Task { [weak self, sleep] in
            do {
                try await sleep(.seconds(1))
            } catch {
                return  // Cancelled: a newer change, Done or disappear took over.
            }
            guard !Task.isCancelled else { return }
            await self?.save()
        }
    }

    /// Writes the current text after any earlier save, through the store and off the main thread. Shows the
    /// error on failure.
    ///
    /// The conversion to RTF stays on the main thread, as it always was: `NSAttributedString` isn't Sendable on
    /// iOS, and the live text belongs to the main actor, so it can't be handed to another thread.
    /// - Returns: false if a save was attempted and failed.
    @discardableResult
    private func save() async -> Bool {
        guard !isReadOnly else { return true }
        let item = item
        let store = store
        let previous = saveTask
        do {
            let data = try attributedText.data(
                from: NSRange(location: 0, length: attributedText.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            // Detached: this project's `nonisolated async` functions run on the caller's actor (approachable
            // concurrency), so a plain `await store.write` could encrypt on the main thread. It holds no
            // reference to self, so a save started as the screen goes away still completes.
            let task = Task.detached {
                _ = await previous?.result
                try await store.write(data, to: item)
            }
            saveTask = task
            try await task.value
            return true
        } catch {
            alerts?.showError(error)
            return false
        }
    }

    // MARK: - Formatting

    func toggleBold() {
        updateFont { Self.toggling(.traitBold, of: $0) }
    }

    func toggleItalic() {
        updateFont { Self.toggling(.traitItalic, of: $0) }
    }

    func toggleUnderline() {
        let current = typingAttributes[.underlineStyle] as? Int ?? 0
        let style = current == 0 ? NSUnderlineStyle.single.rawValue : 0
        typingAttributes[.underlineStyle] = style
        applyToSelection { attributes in attributes[.underlineStyle] = style }
    }

    func increaseFontSize() {
        updateFont { UIFont(descriptor: $0.fontDescriptor, size: $0.pointSize + 2) }
    }

    func decreaseFontSize() {
        updateFont { UIFont(descriptor: $0.fontDescriptor, size: max($0.pointSize - 2, 8)) }
    }

    func setAlignment(_ alignment: NSTextAlignment) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        typingAttributes[.paragraphStyle] = paragraph
        applyToSelection { attributes in attributes[.paragraphStyle] = paragraph }
    }

    private static func toggling(_ trait: UIFontDescriptor.SymbolicTraits, of font: UIFont) -> UIFont {
        let traits = font.fontDescriptor.symbolicTraits.symmetricDifference(trait)
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }

    private func updateFont(_ transform: (UIFont) -> UIFont) {
        let body = UIFont.preferredFont(forTextStyle: .body)
        typingAttributes[.font] = transform(typingAttributes[.font] as? UIFont ?? body)
        applyToSelection { attributes in
            attributes[.font] = transform(attributes[.font] as? UIFont ?? body)
        }
    }

    /// Changes each attribute run of the selection, a formatting change that autosaves like any other.
    private func applyToSelection(_ change: (inout [NSAttributedString.Key: Any]) -> Void) {
        let whole = NSRange(location: 0, length: attributedText.length)
        let selection = NSIntersectionRange(selectedRange, whole)
        guard selection.length > 0 else { return }
        let updated = NSMutableAttributedString(attributedString: attributedText)
        attributedText.enumerateAttributes(in: selection) { attributes, range, _ in
            var changed = attributes
            change(&changed)
            updated.addAttributes(changed, range: range)
        }
        attributedText = updated
        scheduleAutosave()
    }
}

/// Why a document can't be loaded, beyond the store's and the RTF parser's own errors.
private enum TextEditorLoadError: LocalizedError {
    /// The file has content but isn't RTF.
    case notRTF

    var errorDescription: String? {
        "This document isn't a valid RTF file, so it can't be opened."
    }
}
