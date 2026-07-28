//
//  FileCell.swift
//  SecureVault
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
    
    required init?(coder: NSCoder) { fatalError() }
    
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
        
        checkmark = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
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
            iconView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            iconView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            iconView.widthAnchor.constraint(equalTo: contentView.widthAnchor),
            iconView.heightAnchor.constraint(equalToConstant: 80),

            nameLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: -8),
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
    
    func configure(with item: VaultItem, gridMode: Bool) {
        let config = UIImage.SymbolConfiguration(pointSize: 50, weight: .regular)
        iconView.image = FileIconProvider.icon(for: item)?.withConfiguration(config)
        iconView.tintColor = FileIconProvider.iconColor(for: item)
        iconView.contentMode = .center
        nameLabel.text = item.name
        detailLabel.text = item.isDirectory ? "" : formattedSize(item.fileSize)

        thumbnailRequest = ThumbnailService.shared.thumbnail(for: item, size: CGSize(width: 40, height: 40)) { [weak self] image in
            guard let self, let image else { return }
            self.iconView.image = image
            self.iconView.contentMode = .scaleAspectFit
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
        iconView.subviews.forEach { $0.removeFromSuperview() }
        iconView.image = nil
        iconView.contentMode = .center
    }
}
