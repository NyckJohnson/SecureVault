//
//  LegacyTextEditorViewController.swift
//  KoalaTVault
//
//  Created by Nicholas Johnson on 7/12/26.
//

import UIKit

final class LegacyTextEditorViewController: UIViewController, AlertPresenting {

    // MARK: - Properties
    private let item: VaultItem
    private let vaultStore: any VaultStoring
    private var textView: UITextView!
    private var toolbar: UIToolbar!
    private var saveTimer: Timer?
    private var tempDecryptedDir: URL?
    /// Set when the document failed to load; the editor is then read-only and never saves.
    private var didFailToLoad = false
    /// Set once the document has loaded; nothing is saved before, so an empty editor never
    /// overwrites a document still loading.
    private var didLoad = false
    /// Set once `viewWillDisappear` has cleaned up: a load that finishes after that removes its decrypted
    /// copy at once and shows nothing.
    private var didCleanUp = false
    /// The latest save; each save waits for the one before, so writes reach the store in order and newer
    /// content is never overwritten by older.
    private var saveTask: Task<Void, Never>?

    // MARK: - Init
    /// - Parameter vaultStore: the app's vault store, which reads and writes the document.
    init(item: VaultItem, vaultStore: any VaultStoring) {
        self.item = item
        self.vaultStore = vaultStore
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "textEditor"
        title = item.name
        setupNavigationBar()
        setupTextView()
        setupFormattingToolbar()
        loadDocument()
        registerForKeyboardNotifications()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        saveTimer?.invalidate()
        saveTimer = nil
        saveDocument()
        didCleanUp = true
        if let dir = tempDecryptedDir {
            vaultStore.removeTemporary(dir)
            tempDecryptedDir = nil
        }
    }

    // MARK: - Setup
    private func setupNavigationBar() {
        let doneButton = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(dismissEditor)
        )
        doneButton.accessibilityIdentifier = "textEditor.doneButton"
        navigationItem.rightBarButtonItem = doneButton
    }

    private func setupTextView() {
        textView = UITextView()
        textView.font = .preferredFont(forTextStyle: .body)
        textView.allowsEditingTextAttributes = true
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.delegate = self
        textView.accessibilityIdentifier = "textEditor.textView"
        view.addSubview(textView)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func setupFormattingToolbar() {
        toolbar = UIToolbar()
        toolbar.sizeToFit()
        toolbar.accessibilityIdentifier = "textEditor.formattingToolbar"

        let bold = UIBarButtonItem(image: UIImage(systemName: "bold"), style: .plain, target: self, action: #selector(toggleBold))
        let italic = UIBarButtonItem(
            image: UIImage(systemName: "italic"), style: .plain, target: self, action: #selector(toggleItalic))
        let underline = UIBarButtonItem(
            image: UIImage(systemName: "underline"), style: .plain, target: self, action: #selector(toggleUnderlineStyle))
        let increaseFontSize = UIBarButtonItem(
            image: UIImage(systemName: "textformat.size.larger"), style: .plain, target: self, action: #selector(increaseFontSize))
        let decreaseFontSize = UIBarButtonItem(
            image: UIImage(systemName: "textformat.size.smaller"), style: .plain, target: self, action: #selector(decreaseFontSize))
        let alignLeft = UIBarButtonItem(
            image: UIImage(systemName: "text.alignleft"), style: .plain, target: self, action: #selector(alignLeft))
        let alignCenter = UIBarButtonItem(
            image: UIImage(systemName: "text.aligncenter"), style: .plain, target: self, action: #selector(alignCenter))
        let alignRight = UIBarButtonItem(
            image: UIImage(systemName: "text.alignright"), style: .plain, target: self, action: #selector(alignRight))
        let flex = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        bold.accessibilityIdentifier = "textEditor.boldButton"
        italic.accessibilityIdentifier = "textEditor.italicButton"
        underline.accessibilityIdentifier = "textEditor.underlineButton"
        decreaseFontSize.accessibilityIdentifier = "textEditor.decreaseFontSizeButton"
        increaseFontSize.accessibilityIdentifier = "textEditor.increaseFontSizeButton"
        alignLeft.accessibilityIdentifier = "textEditor.alignLeftButton"
        alignCenter.accessibilityIdentifier = "textEditor.alignCenterButton"
        alignRight.accessibilityIdentifier = "textEditor.alignRightButton"

        toolbar.items = [bold, italic, underline, flex, decreaseFontSize, increaseFontSize, flex, alignLeft, alignCenter, alignRight]
        textView.inputAccessoryView = toolbar
    }

    // MARK: - Document
    private func loadDocument() {
        // Read-only until the document is in, so nothing typed is lost to the load.
        textView.isEditable = false
        let vaultStore = vaultStore
        let item = item
        Task { [weak self] in
            let url: URL
            do {
                url = try await vaultStore.open(item)
            } catch {
                guard let self, !self.didCleanUp else { return }
                self.showLoadFailure(error)
                return
            }
            let decryptedDir = item.isEncrypted ? url.deletingLastPathComponent() : nil
            // Dismissed while loading: cleanup has already run, so remove the decrypted copy here.
            guard let self, !self.didCleanUp else {
                if let decryptedDir { vaultStore.removeTemporary(decryptedDir) }
                return
            }
            self.tempDecryptedDir = decryptedDir
            self.showDocument(at: url)
        }
    }

    /// Shows the document at `url` and makes it editable, or shows the load failure.
    private func showDocument(at url: URL) {
        do {
            let data = try Data(contentsOf: url)
            if data.isEmpty {
                textView.text = ""
            } else {
                textView.attributedText = try NSAttributedString(
                    data: data,
                    options: [.documentType: NSAttributedString.DocumentType.rtf],
                    documentAttributes: nil
                )
            }
            didLoad = true
            textView.isEditable = true
        } catch {
            showLoadFailure(error)
        }
    }

    /// Leaves the editor read-only and empty, and never saves it.
    private func showLoadFailure(_ error: Error) {
        didFailToLoad = true
        textView.text = ""
        textView.isEditable = false
        toolbar.items?.forEach { $0.isEnabled = false }
        showError(error)
    }

    private func saveDocument() {
        // Never write over the original with a document that failed to load or hasn't loaded yet.
        guard didLoad, !didFailToLoad else { return }
        let data: Data
        do {
            data = try textView.attributedText.data(
                from: NSRange(location: 0, length: textView.attributedText.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            )
        } catch {
            showError(error)
            return
        }
        let item = item
        let vaultStore = vaultStore
        let previous = saveTask
        // Runs after the previous save, so one write is in flight and the latest content lands last.
        // Holds no strong reference to the editor, so a save started on dismissal still completes.
        saveTask = Task { [weak self] in
            await previous?.value
            do {
                try await vaultStore.write(data, to: item)
            } catch {
                self?.showError(error)
            }
        }
    }

    // MARK: - Keyboard
    private func registerForKeyboardNotifications() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillShow(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    @objc private func keyboardWillShow(_ notification: Notification) {
        guard let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        textView.contentInset.bottom = keyboardFrame.height
        textView.verticalScrollIndicatorInsets.bottom = keyboardFrame.height
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        textView.contentInset.bottom = 0
        textView.verticalScrollIndicatorInsets.bottom = 0
    }

    // MARK: - Actions
    @objc private func dismissEditor() {
        saveDocument()
        dismiss(animated: true)
    }

    @objc private func toggleBold() {
        updateTypingAttribute(.font) { font in
            let isBold = font.fontDescriptor.symbolicTraits.contains(.traitBold)
            let traits: UIFontDescriptor.SymbolicTraits = isBold
                ? font.fontDescriptor.symbolicTraits.subtracting(.traitBold)
                : font.fontDescriptor.symbolicTraits.union(.traitBold)
            guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return font }
            return UIFont(descriptor: descriptor, size: font.pointSize)
        }
    }

    @objc private func toggleItalic() {
        updateTypingAttribute(.font) { font in
            let isItalic = font.fontDescriptor.symbolicTraits.contains(.traitItalic)
            let traits: UIFontDescriptor.SymbolicTraits = isItalic
                ? font.fontDescriptor.symbolicTraits.subtracting(.traitItalic)
                : font.fontDescriptor.symbolicTraits.union(.traitItalic)
            guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return font }
            return UIFont(descriptor: descriptor, size: font.pointSize)
        }
    }

    @objc private func toggleUnderlineStyle() {
        let current = textView.typingAttributes[.underlineStyle] as? Int ?? 0
        textView.typingAttributes[.underlineStyle] = current == 0 ? NSUnderlineStyle.single.rawValue : 0
        applyToSelection { attrs in
            var updatedAttributes = attrs
            updatedAttributes[.underlineStyle] = current == 0 ? NSUnderlineStyle.single.rawValue : 0
            return updatedAttributes
        }
    }

    @objc private func increaseFontSize() {
        updateTypingAttribute(.font) { font in
            UIFont(descriptor: font.fontDescriptor, size: font.pointSize + 2)
        }
    }

    @objc private func decreaseFontSize() {
        updateTypingAttribute(.font) { font in
            UIFont(descriptor: font.fontDescriptor, size: max(font.pointSize - 2, 8))
        }
    }

    @objc private func alignLeft() { setAlignment(.left) }
    @objc private func alignCenter() { setAlignment(.center) }
    @objc private func alignRight() { setAlignment(.right) }

    // MARK: - Helpers
    private func updateTypingAttribute(_ key: NSAttributedString.Key, transform: (UIFont) -> UIFont) {
        let font = textView.typingAttributes[key] as? UIFont ?? .preferredFont(forTextStyle: .body)
        textView.typingAttributes[key] = transform(font)
        applyToSelection { attrs in
            var updatedAttributes = attrs
            let currentFont = updatedAttributes[key] as? UIFont ?? .preferredFont(forTextStyle: .body)
            updatedAttributes[key] = transform(currentFont)
            return updatedAttributes
        }
    }

    private func applyToSelection(transform: ([NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any]) {
        guard textView.selectedRange.length > 0 else { return }
        let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
        textView.attributedText.enumerateAttributes(in: textView.selectedRange) { attrs, range, _ in
            mutable.addAttributes(transform(attrs), range: range)
        }
        let range = textView.selectedRange
        textView.attributedText = mutable
        textView.selectedRange = range
    }

    private func setAlignment(_ alignment: NSTextAlignment) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        textView.typingAttributes[.paragraphStyle] = paragraph
        applyToSelection { attrs in
            var updatedAttributes = attrs
            updatedAttributes[.paragraphStyle] = paragraph
            return updatedAttributes
        }
    }
}

// MARK: - UITextViewDelegate
extension LegacyTextEditorViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveDocument()
            }
        }
    }
}
