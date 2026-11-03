import Combine
import UIKit

/// The rich-text editor screen. Loading, saving and formatting are the view model's.
@MainActor
final class TextEditorViewController: UIViewController, AlertPresenting {
    private let item: VaultItem
    private let store: any VaultStoring
    /// Lazy because it needs this screen as its alert presenter; it holds the screen weakly.
    private lazy var viewModel = TextEditorViewModel(item: item, store: store, alerts: self)
    private let textView = UITextView()
    private let toolbar = UIToolbar()
    private var subscriptions: Set<AnyCancellable> = []
    /// The Try Again or Discard Changes alert while it is up.
    private weak var failedDoneAlert: UIAlertController?

    /// - Parameter store: the app's vault store, which reads and writes the document.
    init(item: VaultItem, store: any VaultStoring) {
        self.item = item
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "textEditor"
        title = item.name
        setupNavigationBar()
        setupTextView()
        setupFormattingToolbar()
        registerForKeyboardNotifications()
        bindViewModel()
        Task { [viewModel] in await viewModel.load() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        Task { [viewModel] in await viewModel.viewDidDisappear() }
    }

    // MARK: - Binding

    private func bindViewModel() {
        // Asking the presenter, not this screen: it removes this screen and any alert still over it.
        viewModel.onDismiss = { [weak self] in
            guard let self else { return }
            (presentingViewController ?? self).dismiss(animated: true)
        }
        viewModel.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.showText() }
            .store(in: &subscriptions)
        // Not deferred, unlike the text: a keystroke arriving before a deferred update would miss Done's save.
        Publishers.CombineLatest(viewModel.$isReadOnly, viewModel.$isFinishing)
            .map { isReadOnly, isFinishing in !isReadOnly && !isFinishing }
            .removeDuplicates()
            .sink { [weak self] canEdit in self?.setEditable(canEdit) }
            .store(in: &subscriptions)
        // Every failed Done sets the message anew, even an identical one, so each failure shows the alert again.
        viewModel.$failedDoneMessage
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in self?.showFailedDoneAlert(message) }
            .store(in: &subscriptions)
        showText()
    }

    private func setEditable(_ canEdit: Bool) {
        textView.isEditable = canEdit
        toolbar.items?.forEach { $0.isEnabled = canEdit }
    }

    /// Only when the text differs: setting it moves the selection and resets the typing attributes.
    private func showText() {
        guard !textView.attributedText.isEqual(to: viewModel.attributedText) else { return }
        let selection = textView.selectedRange
        textView.attributedText = viewModel.attributedText
        textView.selectedRange = selection
    }

    // MARK: - Failed Done

    private func showFailedDoneAlert(_ message: String) {
        guard failedDoneAlert == nil else { return }
        let alert = UIAlertController(title: "Error", message: message, preferredStyle: .alert)
        alert.addAction(
            UIAlertAction(title: "Try Again", style: .default) { [weak self] _ in
                self?.afterFailedDoneAlertCloses { $0.doneTapped() }
            })
        alert.addAction(
            UIAlertAction(title: "Discard Changes", style: .destructive) { [weak self] _ in
                self?.afterFailedDoneAlertCloses { $0.viewModel.discardChanges() }
            })
        failedDoneAlert = alert
        // From the topmost, as `showError` does: an autosave's error can already be up when Done's save fails.
        topmostPresentedController.present(alert, animated: true)
    }

    /// Runs `action` with the alert off the screen. While it is still leaving, UIKit would refuse to present the next
    /// failure's alert over it, and dismissing this screen would only close the alert.
    private func afterFailedDoneAlertCloses(_ action: @escaping @MainActor (TextEditorViewController) -> Void) {
        let coordinator = failedDoneAlert?.transitionCoordinator
        failedDoneAlert = nil
        let queued = coordinator?.animate(alongsideTransition: nil) { [weak self] _ in
            if let self { action(self) }
        }
        if queued != true { action(self) }
    }

    // MARK: - Setup

    private func setupNavigationBar() {
        let doneButton = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(doneTapped))
        doneButton.accessibilityIdentifier = "textEditor.doneButton"
        navigationItem.rightBarButtonItem = doneButton
    }

    private func setupTextView() {
        textView.font = .preferredFont(forTextStyle: .body)
        textView.allowsEditingTextAttributes = true
        textView.isEditable = false
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.delegate = self
        textView.accessibilityIdentifier = "textEditor.textView"
        view.addSubview(textView)

        var constraints: [NSLayoutConstraint] = []
        constraints.append(textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor))
        constraints.append(textView.leadingAnchor.constraint(equalTo: view.leadingAnchor))
        constraints.append(textView.trailingAnchor.constraint(equalTo: view.trailingAnchor))
        constraints.append(textView.bottomAnchor.constraint(equalTo: view.bottomAnchor))
        NSLayoutConstraint.activate(constraints)
    }

    private func setupFormattingToolbar() {
        toolbar.sizeToFit()
        toolbar.accessibilityIdentifier = "textEditor.formattingToolbar"
        let flex = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        var items: [UIBarButtonItem] = []
        items.append(formatButton("bold", "boldButton", #selector(toggleBold)))
        items.append(formatButton("italic", "italicButton", #selector(toggleItalic)))
        items.append(formatButton("underline", "underlineButton", #selector(toggleUnderlineStyle)))
        items.append(flex)
        items.append(formatButton("textformat.size.smaller", "decreaseFontSizeButton", #selector(decreaseFontSize)))
        items.append(formatButton("textformat.size.larger", "increaseFontSizeButton", #selector(increaseFontSize)))
        items.append(flex)
        items.append(formatButton("text.alignleft", "alignLeftButton", #selector(alignLeft)))
        items.append(formatButton("text.aligncenter", "alignCenterButton", #selector(alignCenter)))
        items.append(formatButton("text.alignright", "alignRightButton", #selector(alignRight)))
        toolbar.items = items
        textView.inputAccessoryView = toolbar
    }

    private func formatButton(_ symbol: String, _ identifier: String, _ action: Selector) -> UIBarButtonItem {
        let button = UIBarButtonItem(image: UIImage(systemName: symbol), style: .plain, target: self, action: action)
        button.accessibilityIdentifier = "textEditor.\(identifier)"
        return button
    }

    // MARK: - Keyboard

    private func registerForKeyboardNotifications() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillShow(_:)), name: UIResponder.keyboardWillShowNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil
        )
    }

    /// The text view reaches the screen's bottom and already adds the bottom safe area to its adjusted inset, so
    /// only the part of the keyboard above the safe area is added here.
    @objc private func keyboardWillShow(_ notification: Notification) {
        guard let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            return
        }
        let overlap = view.bounds.maxY - view.convert(keyboardFrame, from: nil).minY
        setBottomInset(max(overlap - view.safeAreaInsets.bottom, 0))
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        setBottomInset(0)
    }

    private func setBottomInset(_ inset: CGFloat) {
        textView.contentInset.bottom = inset
        textView.verticalScrollIndicatorInsets.bottom = inset
    }

    // MARK: - Actions

    @objc private func doneTapped() {
        Task { [viewModel] in await viewModel.done() }
    }

    @objc private func toggleBold() { format { $0.toggleBold() } }
    @objc private func toggleItalic() { format { $0.toggleItalic() } }
    @objc private func toggleUnderlineStyle() { format { $0.toggleUnderline() } }
    @objc private func increaseFontSize() { format { $0.increaseFontSize() } }
    @objc private func decreaseFontSize() { format { $0.decreaseFontSize() } }
    @objc private func alignLeft() { format { $0.setAlignment(.left) } }
    @objc private func alignCenter() { format { $0.setAlignment(.center) } }
    @objc private func alignRight() { format { $0.setAlignment(.right) } }

    /// Gives the model the text view's selection and typing attributes, applies the change, and copies the result
    /// back at once so the selection and the typing attributes survive it.
    private func format(_ change: (TextEditorViewModel) -> Void) {
        viewModel.selectedRange = textView.selectedRange
        viewModel.typingAttributes = textView.typingAttributes
        change(viewModel)
        showText()
        textView.typingAttributes = viewModel.typingAttributes
    }
}

// MARK: - UITextViewDelegate

extension TextEditorViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        viewModel.textDidChange(textView.attributedText)
    }
}
