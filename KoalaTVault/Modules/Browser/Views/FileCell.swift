import UIKit

/// One grid cell of the file browser: the item's icon (replaced by its thumbnail when one arrives), name, size
/// text, and a checkmark in select mode. What it shows comes from `FileCellModel`.
@MainActor
final class FileCell: UICollectionViewCell {
    static let reuseID = "FileCell"

    /// Shows the item's icon, then its thumbnail.
    let thumbnailView = UIImageView()
    private let nameLabel = UILabel()
    private let detailLabel = UILabel()
    private let checkmark = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))

    /// The model of the item shown now; replaced on each `configure`.
    private var model: FileCellModel?
    /// The task waiting for the shown item's thumbnail.
    private var thumbnailTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUpViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpViews()
    }

    private func setUpViews() {
        thumbnailView.contentMode = .center
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .preferredFont(forTextStyle: .caption1)
        nameLabel.textAlignment = .center
        nameLabel.numberOfLines = 2
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = .preferredFont(forTextStyle: .caption2)
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .center
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        checkmark.tintColor = .systemBlue
        checkmark.translatesAutoresizingMaskIntoConstraints = false
        checkmark.isHidden = true
        checkmark.backgroundColor = .white
        checkmark.layer.cornerRadius = 12
        checkmark.clipsToBounds = true

        contentView.addSubview(thumbnailView)
        contentView.addSubview(nameLabel)
        contentView.addSubview(detailLabel)
        contentView.addSubview(checkmark)

        NSLayoutConstraint.activate([
            thumbnailView.topAnchor.constraint(equalTo: contentView.topAnchor),
            thumbnailView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            thumbnailView.widthAnchor.constraint(equalTo: contentView.widthAnchor),
            thumbnailView.heightAnchor.constraint(equalToConstant: 80),

            nameLabel.topAnchor.constraint(equalTo: thumbnailView.bottomAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),

            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            detailLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            detailLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),

            checkmark.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            checkmark.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            checkmark.widthAnchor.constraint(equalToConstant: 24),
            checkmark.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    /// Shows `item`, and asks `thumbnails` for its thumbnail.
    /// - Parameters:
    ///   - item: the item to show.
    ///   - thumbnails: makes and caches thumbnails.
    ///   - folderAssetAvailable: whether the bundle has the folder image.
    func configure(with item: VaultItem, thumbnails: any ThumbnailProviding, folderAssetAvailable: Bool) {
        clearShownItem()
        let model = FileCellModel(thumbnails: thumbnails, folderAssetAvailable: folderAssetAvailable)
        model.configure(with: item)
        self.model = model

        nameLabel.text = model.name
        detailLabel.text = model.sizeText
        if let icon = model.icon {
            let shown = Self.iconImage(for: icon)
            thumbnailView.image = shown.image
            thumbnailView.tintColor = shown.tint
            thumbnailView.contentMode = shown.isAsset ? .scaleAspectFit : .center
        }

        accessibilityIdentifier = "browser.cell.\(item.name)"
        nameLabel.accessibilityIdentifier = "browser.cell.\(item.name).nameLabel"
        detailLabel.accessibilityIdentifier = "browser.cell.\(item.name).sizeLabel"
        checkmark.accessibilityIdentifier = "browser.cell.\(item.name).checkmark"

        let scale = traitCollection.displayScale
        thumbnailTask = Task { [weak self, model] in
            let image = await model.thumbnail(size: CGSize(width: 40, height: 40), scale: scale)
            // The model drops a thumbnail for an item the cell no longer shows; a new model means the same.
            guard let self, let image, !Task.isCancelled, self.model === model else { return }
            self.thumbnailView.image = image
            self.thumbnailView.contentMode = .scaleAspectFit
        }
    }

    /// Shows the select-mode checkmark when the item is chosen, and dims unchosen items in select mode.
    func setSelected(_ selected: Bool, inSelectMode: Bool) {
        checkmark.isHidden = !inSelectMode || !selected
        contentView.alpha = inSelectMode && !selected ? 0.6 : 1.0
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        clearShownItem()
        thumbnailView.image = nil
        thumbnailView.contentMode = .center
        setSelected(false, inSelectMode: false)
    }

    /// Cancels the shown item's thumbnail (task and request) and forgets the item.
    private func clearShownItem() {
        thumbnailTask?.cancel()
        thumbnailTask = nil
        model?.prepareForReuse()
        model = nil
    }

    // MARK: - File icons

    /// The image and tint for `icon`: the folder asset when the icon names it and the bundle has it,
    /// otherwise the folder fallback symbol (24 pt) or the file's SF Symbol (50 pt).
    private static func iconImage(for icon: FileIcon) -> IconImage {
        if icon.usesFolderAsset {
            if let asset = UIImage(named: icon.symbolName) {
                return IconImage(image: asset, tint: tintColor(named: icon.tintName), isAsset: true)
            }
            let fallback = FileIconMapping.icon(for: .other, isDirectory: true, folderAssetAvailable: false)
            let image = UIImage(systemName: fallback.symbolName)?
                .withConfiguration(UIImage.SymbolConfiguration(pointSize: 24, weight: .regular))
            return IconImage(image: image, tint: tintColor(named: fallback.tintName), isAsset: false)
        }
        let image = UIImage(systemName: icon.symbolName)?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 50, weight: .regular))
        return IconImage(image: image, tint: tintColor(named: icon.tintName), isAsset: false)
    }

    /// An icon ready to show: the image, its tint, and whether it is the folder asset (scaled to fit).
    private struct IconImage {
        let image: UIImage?
        let tint: UIColor
        let isAsset: Bool
    }

    /// The `UIColor` a `FileIcon.tintName` names.
    private static func tintColor(named name: String) -> UIColor {
        switch name {
        case "clear": .clear
        case "systemYellow": .systemYellow
        case "systemGreen": .systemGreen
        case "systemPurple": .systemPurple
        case "systemPink": .systemPink
        case "systemRed": .systemRed
        case "systemBlue": .systemBlue
        case "systemOrange": .systemOrange
        case "systemBrown": .systemBrown
        default: .systemGray
        }
    }
}
