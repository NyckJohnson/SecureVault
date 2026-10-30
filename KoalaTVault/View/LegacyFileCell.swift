//
//  LegacyFileCell.swift
//  KoalaTVault
//
//  Created by Nicholas Johnson on 5/10/26.
//

import UIKit

final class LegacyFileCell: UICollectionViewCell {
    static let reuseID = "FileCell"
    
    private let iconView    = UIImageView()
    private let nameLabel   = UILabel()
    private let detailLabel = UILabel()
    private var checkmark = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
    /// A pending thumbnail request: the item it is for, the provider asked, and the task awaiting it.
    private struct ThumbnailRequest {
        let item: VaultItem
        let provider: any ThumbnailProviding
        let task: Task<Void, Never>
    }
    private var thumbnailRequest: ThumbnailRequest?
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }
    
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    
    private func setupViews() {
        iconView.contentMode = .center
        iconView.translatesAutoresizingMaskIntoConstraints = false
        
        nameLabel.font          = .preferredFont(forTextStyle: .caption1)
        nameLabel.textAlignment = .center
        nameLabel.numberOfLines = 2
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        
        detailLabel.font          = .preferredFont(forTextStyle: .caption2)
        detailLabel.textColor     = .secondaryLabel
        detailLabel.textAlignment = .center
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        
        checkmark.tintColor = .systemBlue
        checkmark.translatesAutoresizingMaskIntoConstraints = false
        checkmark.isHidden = true
        checkmark.backgroundColor = .white
        checkmark.layer.cornerRadius = 12
        checkmark.clipsToBounds = true
        
        contentView.addSubview(iconView)
        contentView.addSubview(nameLabel)
        contentView.addSubview(detailLabel)
        contentView.addSubview(checkmark)

        NSLayoutConstraint.activate([
            // iconView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 3),
            iconView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            iconView.widthAnchor.constraint(equalTo: contentView.widthAnchor),
            iconView.heightAnchor.constraint(equalToConstant: 80),

            nameLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 0),
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),

            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            detailLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            detailLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),

            checkmark.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            checkmark.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            checkmark.widthAnchor.constraint(equalToConstant: 24),
            checkmark.heightAnchor.constraint(equalToConstant: 24)
        ])
        
        /* debug borders
        contentView.layer.borderWidth = 1
        contentView.layer.borderColor = UIColor.red.cgColor

        iconView.layer.borderWidth = 1
        iconView.layer.borderColor = UIColor.blue.cgColor

        nameLabel.layer.borderWidth = 1
        nameLabel.layer.borderColor = UIColor.green.cgColor

        detailLabel.layer.borderWidth = 1
        detailLabel.layer.borderColor = UIColor.orange.cgColor
        */
    }
    
    /// Shows `item`; its thumbnail comes from `thumbnails` (the app's one thumbnail service).
    func configure(with item: VaultItem, gridMode: Bool, thumbnails: any ThumbnailProviding) {
        let config = UIImage.SymbolConfiguration(pointSize: 50, weight: .regular)
        let (icon, tint) = Self.iconImageAndTint(for: item)
        
        // only apply symbol config to SF Symbols, not custom assets
        iconView.image       = item.isDirectory ? icon : icon?.withConfiguration(config)
        iconView.tintColor   = tint
        iconView.contentMode = item.isDirectory ? .scaleAspectFit : .center
        nameLabel.text       = item.name
        detailLabel.text     = item.isDirectory ? "" : formattedSize(item.fileSize)

        // for ui tests
        nameLabel.accessibilityIdentifier   = "browser.cell.\(item.name).nameLabel"
        detailLabel.accessibilityIdentifier = "browser.cell.\(item.name).sizeLabel"
        checkmark.accessibilityIdentifier   = "browser.cell.\(item.name).checkmark"

        cancelThumbnailRequest()
        // UIScreen must only be read on the main thread; this cell is main-actor isolated.
        let scale = UIScreen.main.scale
        let task = Task { [weak self] in
            let image = await thumbnails.thumbnail(for: item, size: CGSize(width: 40, height: 40), scale: scale)
            // Ignore a result for an item this cell no longer shows (reused, or the request was cancelled).
            guard let self, !Task.isCancelled, let image,
                  self.thumbnailRequest?.item.id == item.id else { return }
            self.thumbnailRequest = nil
            self.iconView.image = image
            self.iconView.contentMode = .scaleAspectFit
        }
        thumbnailRequest = ThumbnailRequest(item: item, provider: thumbnails, task: task)
    }

    /// Cancels the pending thumbnail request, if any, so its work stops and its result is dropped.
    private func cancelThumbnailRequest() {
        guard let request = thumbnailRequest else { return }
        thumbnailRequest = nil
        request.task.cancel()
        request.provider.cancel(request.item)
    }
    
    func setSelected(_ selected: Bool, inSelectMode: Bool) {
        checkmark.isHidden = !inSelectMode || !selected
        contentView.alpha = inSelectMode && !selected ? 0.6 : 1.0
    }
    
    private func formattedSize(_ size: Int?) -> String {
        guard let size else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        cancelThumbnailRequest()
        iconView.image = nil
        iconView.contentMode = .center
    }

    // MARK: - File icons

    /// The image and tint for `item`, from SharedUI's `FileIconMapping`: the folder asset when the
    /// bundle has it, otherwise the SF Symbol (the folder fallback symbol at 24 pt).
    private static func iconImageAndTint(for item: VaultItem) -> (image: UIImage?, tint: UIColor) {
        var icon = FileIconMapping.icon(for: item.kind, isDirectory: item.isDirectory, folderAssetAvailable: true)
        if icon.usesFolderAsset {
            if let asset = UIImage(named: icon.symbolName) {
                return (asset, tintColor(named: icon.tintName))
            }
            icon = FileIconMapping.icon(for: item.kind, isDirectory: item.isDirectory, folderAssetAvailable: false)
        }
        var image = UIImage(systemName: icon.symbolName)
        if item.isDirectory {
            image = image?.withConfiguration(UIImage.SymbolConfiguration(pointSize: 24, weight: .regular))
        }
        return (image, tintColor(named: icon.tintName))
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
