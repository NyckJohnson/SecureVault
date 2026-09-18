//
//  TextEditorViewController.swift
//  SecureVault
//
//  Created by Nicholas Johnson on 7/12/26.
//

import UIKit

final class TextEditorViewController: UIViewController, ErrorPresenting {

    // MARK: - Properties
    private let item: VaultItem
    private var textView: UITextView!
    private var toolbar: UIToolbar!
    private var saveTimer: Timer?

    // MARK: - Init
    init(item: VaultItem) {
        self.item = item
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = item.name
        setupNavigationBar()
        setupTextView()
        setupFormattingToolbar()
        loadDocument()
        registerForKeyboardNotifications()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        saveDocument()
    }

    // MARK: - Setup
    private func setupNavigationBar() {
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(dismissEditor)
        )
    }

    private func setupTextView() {
        textView = UITextView()
        textView.font = .preferredFont(forTextStyle: .body)
        textView.allowsEditingTextAttributes = true
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.delegate = self
        view.addSubview(textView)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func setupFormattingToolbar() {
        toolbar = UIToolbar()
        toolbar.sizeToFit()

        let bold = UIBarButtonItem(image: UIImage(systemName: "bold"), style: .plain, target: self, action: #selector(toggleBold))
        let italic = UIBarButtonItem(image: UIImage(systemName: "italic"), style: .plain, target: self, action: #selector(toggleItalic))
        let underline = UIBarButtonItem(image: UIImage(systemName: "underline"), style: .plain, target: self, action: #selector(toggleUnderlineStyle))
        let increaseFontSize = UIBarButtonItem(image: UIImage(systemName: "textformat.size.larger"), style: .plain, target: self, action: #selector(increaseFontSize))
        let decreaseFontSize = UIBarButtonItem(image: UIImage(systemName: "textformat.size.smaller"), style: .plain, target: self, action: #selector(decreaseFontSize))
        let alignLeft = UIBarButtonItem(image: UIImage(systemName: "text.alignleft"), style: .plain, target: self, action: #selector(alignLeft))
        let alignCenter = UIBarButtonItem(image: UIImage(systemName: "text.aligncenter"), style: .plain, target: self, action: #selector(alignCenter))
        let alignRight = UIBarButtonItem(image: UIImage(systemName: "text.alignright"), style: .plain, target: self, action: #selector(alignRight))
        let flex = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)

        toolbar.items = [bold, italic, underline, flex, decreaseFontSize, increaseFontSize, flex, alignLeft, alignCenter, alignRight]
        textView.inputAccessoryView = toolbar
    }

    // MARK: - Document
    private func loadDocument() {
        do {
            let url = try FileSystem.shared.open(item)
            let data = try Data(contentsOf: url)
            guard !data.isEmpty else {
                textView.text = ""
                return
            }
            let attributed = try NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            )
            textView.attributedText = attributed
        } catch {
            showError(error)
            textView.text = ""
        }
    }

    private func saveDocument() {
        do {
            let data = try textView.attributedText.data(
                from: NSRange(location: 0, length: textView.attributedText.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            )
            try FileSystem.shared.write(data: data, to: item)
        } catch {
            showError(error)
        }
    }

    // MARK: - Keyboard
    private func registerForKeyboardNotifications() {
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
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
            var a = attrs
            a[.underlineStyle] = current == 0 ? NSUnderlineStyle.single.rawValue : 0
            return a
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
            var a = attrs
            let f = a[key] as? UIFont ?? .preferredFont(forTextStyle: .body)
            a[key] = transform(f)
            return a
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
            var a = attrs
            a[.paragraphStyle] = paragraph
            return a
        }
    }
}

// MARK: - UITextViewDelegate
extension TextEditorViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            self?.saveDocument()
        }
    }
}
