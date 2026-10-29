//
//  LegacyFileCell.swift
//  KoalaTVault
//
//  Created by Nicholas Johnson on 5/10/26.
//

import UIKit
import QuickLookThumbnailing

final class LegacyFileCell: UICollectionViewCell {
    static let reuseID = "FileCell"
    
    private let iconView    = UIImageView()
    private let nameLabel   = UILabel()
    private let detailLabel = UILabel()
    private var checkmark = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
    private var thumbnailRequest: QLThumbnailGenerator.Request?
    
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
    func configure(with item: VaultItem, gridMode: Bool, thumbnails: ThumbnailService) {
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

        thumbnailRequest = thumbnails.thumbnail(for: item, size: CGSize(width: 40, height: 40)) { [weak self] image in
            guard let self, let image else { return }
            self.iconView.image = image
            self.iconView.contentMode = .scaleAspectFit
            
            /* borders for dsign
            self.iconView.layer.borderWidth = 2
            self.iconView.layer.borderColor = UIColor.purple.cgColor
            */
        }
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
        thumbnailRequest = nil
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
