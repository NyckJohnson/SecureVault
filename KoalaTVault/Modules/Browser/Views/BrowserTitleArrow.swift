import UIKit

/// The title row's back arrow: a backward chevron (flipped in right-to-left layouts), followed by a lock on a
/// vault's root. At least 44 pt square to tap; one accessibility button ("Back" or "Lock").
final class BrowserTitleArrow: UIControl {
    private let stack = UIStackView()

    init(showsLock: Bool) {
        super.init(frame: .zero)
        let config = UIImage.SymbolConfiguration(textStyle: .title2, scale: .large)
            .applying(UIImage.SymbolConfiguration(weight: .semibold))
        var symbols = ["chevron.backward"]
        if showsLock { symbols.append("lock") }
        for name in symbols {
            let imageView = UIImageView(image: UIImage(systemName: name, withConfiguration: config))
            imageView.contentMode = .center
            imageView.adjustsImageSizeForAccessibilityContentSizeCategory = true
            stack.addArrangedSubview(imageView)
        }
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 4
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = showsLock ? "Lock" : "Back"
        accessibilityIdentifier = showsLock ? "lockButton" : "browser.backButton"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var isHighlighted: Bool {
        didSet { stack.alpha = isHighlighted ? 0.4 : 1 }
    }
}
