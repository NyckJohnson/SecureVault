import UIKit

/// A dimming overlay with a card showing a title, a progress bar, a status line ("Preparing..." at
/// first) and an optional Cancel button. Show it with `show(in:title:cancellable:onCancel:)`.
///
/// `update(progress:status:)` and `dismiss()` are main-actor and safe to call repeatedly: updates
/// after dismissal are ignored, and only the first `dismiss()` animates the overlay out.
final class ProgressOverlayView: UIView {
    private let containerView = UIView()
    private let titleLabel = UILabel()
    private let progressBar = UIProgressView(progressViewStyle: .default)
    private let statusLabel = UILabel()
    private let cancelButton = UIButton(type: .system)
    private var onCancel: (() -> Void)?
    private var isDismissed = false

    /// Adds a new overlay covering `viewController`'s view and returns it.
    /// - Parameters:
    ///   - title: The text shown above the progress bar.
    ///   - cancellable: Whether a Cancel button is shown.
    ///   - onCancel: Called when Cancel is tapped, before the overlay dismisses itself.
    @discardableResult
    static func show(
        in viewController: UIViewController,
        title: String,
        cancellable: Bool = false,
        onCancel: (() -> Void)? = nil
    ) -> ProgressOverlayView {
        let overlay = ProgressOverlayView(frame: viewController.view.bounds)
        overlay.titleLabel.text = title
        overlay.onCancel = onCancel
        overlay.cancelButton.isHidden = !cancellable
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        viewController.view.addSubview(overlay)
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

    @objc private func cancelTapped() {
        guard !isDismissed else { return }
        onCancel?()
        dismiss()
    }

    private func setUpViews() {
        backgroundColor = UIColor.black.withAlphaComponent(0.5)

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
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        progressBar.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .preferredFont(forTextStyle: .caption1)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.text = "Preparing..."
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        containerView.addSubview(titleLabel)
        containerView.addSubview(progressBar)
        containerView.addSubview(statusLabel)
        containerView.addSubview(cancelButton)

        // Built by appends rather than one array literal: swift-format and swiftlint disagree on
        // the trailing comma of a multiline literal.
        var constraints: [NSLayoutConstraint] = []
        constraints.append(containerView.centerXAnchor.constraint(equalTo: centerXAnchor))
        constraints.append(containerView.centerYAnchor.constraint(equalTo: centerYAnchor))
        constraints.append(containerView.widthAnchor.constraint(equalToConstant: 300))

        constraints.append(titleLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 24))
        constraints.append(progressBar.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16))
        constraints.append(statusLabel.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 8))
        for row: UIView in [titleLabel, progressBar, statusLabel] {
            constraints.append(row.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16))
            constraints.append(row.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16))
        }

        constraints.append(cancelButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 16))
        constraints.append(cancelButton.centerXAnchor.constraint(equalTo: containerView.centerXAnchor))
        constraints.append(cancelButton.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -16))
        NSLayoutConstraint.activate(constraints)
    }
}
