import UIKit

/// A dimming overlay with a card showing a title, a progress bar, a status line ("Preparing..." at
/// first) and an optional Cancel button. Show it with `show(in:title:style:status:cancellable:onCancel:)`.
/// The `.activity` style shows a spinning activity indicator in place of the progress bar.
///
/// The overlay covers the presenting screen's navigation controller view when it has one, so the
/// navigation bar can't be tapped behind it, and it is modal for VoiceOver.
///
/// `update(progress:status:)` and `dismiss()` are main-actor and safe to call repeatedly: updates
/// after dismissal are ignored, and only the first `dismiss()` animates the overlay out.
final class ProgressOverlayView: UIView {
    /// What the overlay shows below its title.
    enum Style {
        /// A determinate progress bar, driven by `update(progress:status:)`.
        case progress
        /// An animating activity indicator in place of the bar, for work without measurable progress.
        case activity
    }

    private let containerView = UIView()
    private let titleLabel = UILabel()
    private let progressBar = UIProgressView(progressViewStyle: .default)
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let statusLabel = UILabel()
    private let cancelButton = UIButton(type: .system)
    private var onCancel: (() -> Void)?
    private var isDismissed = false

    /// Adds a new overlay covering `viewController`'s screen and returns it. The overlay goes on the
    /// navigation controller's view when `viewController` has one (covering the navigation bar),
    /// otherwise on `viewController.view`.
    /// - Parameters:
    ///   - title: The text shown above the progress bar or activity indicator.
    ///   - style: `.progress` (a progress bar) or `.activity` (an activity indicator, no bar).
    ///   - status: The status line shown at first; `nil` keeps "Preparing...".
    ///   - cancellable: Whether a Cancel button is shown.
    ///   - onCancel: Called when Cancel is tapped, before the overlay dismisses itself.
    @discardableResult
    static func show(
        in viewController: UIViewController,
        title: String,
        style: Style = .progress,
        status: String? = nil,
        cancellable: Bool = false,
        onCancel: (() -> Void)? = nil
    ) -> ProgressOverlayView {
        let host: UIView = viewController.navigationController?.view ?? viewController.view
        let overlay = ProgressOverlayView(frame: host.bounds)
        overlay.titleLabel.text = title
        if let status {
            overlay.statusLabel.text = status
        }
        overlay.apply(style)
        overlay.onCancel = onCancel
        overlay.cancelButton.isHidden = !cancellable
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(overlay)
        return overlay
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUpViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpViews()
    }

    /// Sets the progress bar (0...1) and the status line. Ignored once the overlay is dismissed.
    func update(progress: Float, status: String) {
        guard !isDismissed else { return }
        progressBar.setProgress(progress, animated: false)
        updateProgressAccessibilityValue()
        statusLabel.text = status
    }

    /// Fades the overlay out and removes it. Later calls do nothing.
    func dismiss() {
        guard !isDismissed else { return }
        isDismissed = true
        onCancel = nil
        UIView.animate(withDuration: 0.2) {
            self.alpha = 0
        } completion: { _ in
            self.removeFromSuperview()
        }
    }

    private func apply(_ style: Style) {
        switch style {
        case .progress:
            progressBar.isHidden = false
            activityIndicator.stopAnimating()
            activityIndicator.isHidden = true
        case .activity:
            progressBar.isHidden = true
            activityIndicator.isHidden = false
            activityIndicator.startAnimating()
        }
    }

    /// Announces the bar's progress to VoiceOver as a whole percentage, e.g. "42%".
    private func updateProgressAccessibilityValue() {
        let percent = Int((min(max(progressBar.progress, 0), 1) * 100).rounded())
        progressBar.accessibilityValue = "\(percent)%"
    }

    @objc private func cancelTapped() {
        guard !isDismissed else { return }
        onCancel?()
        dismiss()
    }

    private func setUpViews() {
        backgroundColor = UIColor.black.withAlphaComponent(0.5)
        accessibilityViewIsModal = true

        // Identifiers the UI tests use.
        accessibilityIdentifier = "progressOverlay"
        titleLabel.accessibilityIdentifier = "progressOverlay.titleLabel"
        progressBar.accessibilityIdentifier = "progressOverlay.progressBar"
        statusLabel.accessibilityIdentifier = "progressOverlay.statusLabel"
        cancelButton.accessibilityIdentifier = "progressOverlay.cancelButton"

        containerView.backgroundColor = .systemBackground
        containerView.layer.cornerRadius = 16
        containerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(containerView)

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        progressBar.accessibilityLabel = "Progress"
        updateProgressAccessibilityValue()

        activityIndicator.hidesWhenStopped = true
        activityIndicator.isHidden = true

        // The bar and the indicator share one slot; the hidden one collapses out of the stack.
        let indicatorStack = UIStackView(arrangedSubviews: [progressBar, activityIndicator])
        indicatorStack.axis = .vertical
        indicatorStack.alignment = .fill
        indicatorStack.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .preferredFont(forTextStyle: .caption1)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.text = "Preparing..."
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        containerView.addSubview(titleLabel)
        containerView.addSubview(indicatorStack)
        containerView.addSubview(statusLabel)
        containerView.addSubview(cancelButton)

        // Built by appends rather than one array literal: swift-format and swiftlint disagree on
        // the trailing comma of a multiline literal.
        var constraints: [NSLayoutConstraint] = []
        constraints.append(containerView.centerXAnchor.constraint(equalTo: centerXAnchor))
        constraints.append(containerView.centerYAnchor.constraint(equalTo: centerYAnchor))
        constraints.append(containerView.widthAnchor.constraint(equalToConstant: 300))

        constraints.append(titleLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 24))
        constraints.append(indicatorStack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16))
        constraints.append(statusLabel.topAnchor.constraint(equalTo: indicatorStack.bottomAnchor, constant: 8))
        for row: UIView in [titleLabel, indicatorStack, statusLabel] {
            constraints.append(row.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16))
            constraints.append(row.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16))
        }

        constraints.append(cancelButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 16))
        constraints.append(cancelButton.centerXAnchor.constraint(equalTo: containerView.centerXAnchor))
        constraints.append(cancelButton.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -16))
        NSLayoutConstraint.activate(constraints)
    }
}
