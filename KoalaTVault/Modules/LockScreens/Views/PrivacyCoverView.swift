import UIKit

/// Hides the app's content while the scene is inactive: a plain background with the lock logo.
final class PrivacyCoverView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        accessibilityIdentifier = "privacyCover"
        autoresizingMask = [.flexibleWidth, .flexibleHeight]

        let logo = UIImageView(image: UIImage(systemName: "lock.fill"))
        logo.tintColor = .systemBlue
        logo.contentMode = .scaleAspectFit
        logo.translatesAutoresizingMaskIntoConstraints = false
        addSubview(logo)
        // Appends, not one literal: swift-format and swiftlint disagree on its trailing comma.
        var constraints: [NSLayoutConstraint] = []
        constraints.append(logo.centerXAnchor.constraint(equalTo: centerXAnchor))
        constraints.append(logo.centerYAnchor.constraint(equalTo: centerYAnchor))
        constraints.append(logo.widthAnchor.constraint(equalToConstant: 60))
        constraints.append(logo.heightAnchor.constraint(equalToConstant: 60))
        NSLayoutConstraint.activate(constraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}
