//
//  FileCell.swift
//  KoalaTVault
//
//  Created by Nicholas Johnson on 5/10/26.
//

import UIKit
import QuickLookThumbnailing

final class FileCell: UICollectionViewCell {
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
    
    func configure(with item: VaultItem, gridMode: Bool) {
        let config = UIImage.SymbolConfiguration(pointSize: 50, weight: .regular)
        let icon = FileIconProvider.icon(for: item)
        
        // only apply symbol config to SF Symbols, not custom assets
        iconView.image       = item.isDirectory ? icon : icon?.withConfiguration(config)
        iconView.tintColor   = FileIconProvider.iconColor(for: item)
        iconView.contentMode = item.isDirectory ? .scaleAspectFit : .center
        nameLabel.text       = item.name
        detailLabel.text     = item.isDirectory ? "" : formattedSize(item.fileSize)

        // for ui tests
        nameLabel.accessibilityIdentifier   = "browser.cell.\(item.name).nameLabel"
        detailLabel.accessibilityIdentifier = "browser.cell.\(item.name).sizeLabel"
        checkmark.accessibilityIdentifier   = "browser.cell.\(item.name).checkmark"

        thumbnailRequest = ThumbnailService.shared.thumbnail(for: item, size: CGSize(width: 40, height: 40)) { [weak self] image in
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
}
