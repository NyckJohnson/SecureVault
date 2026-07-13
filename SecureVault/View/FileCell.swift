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
    private var thumbnailTask: QLThumbnailGenerator.Request?
    private var checkmark = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
    
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
    
    func configure(with item: FileItem, gridMode: Bool) {
        let config = UIImage.SymbolConfiguration(pointSize: 80, weight: .regular)
        iconView.image              = FileIconProvider.icon(for: item)?.withConfiguration(config)
        iconView.tintColor          = FileIconProvider.iconColor(for: item)
        iconView.contentMode        = .center
        iconView.layer.cornerRadius = 0
        iconView.clipsToBounds      = false
        
        nameLabel.text       = item.name
        detailLabel.text     = item.isDirectory ? "" : formattedSize(item.fileSize)
        nameLabel.textAlignment   = gridMode ? .center : .left
        detailLabel.textAlignment = gridMode ? .center : .left
        
        if item.isDirectory {
            loadFolderThumbnail(for: item)
        } else if !item.isDirectory {
            loadThumbnail(for: item)
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
    
    private func generateThumbnail(for url: URL, completion: @escaping (UIImage) -> Void) {
        let size = CGSize(width: 100, height: 100)
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size:   size,
            scale:  UIScreen.main.scale,
            representationTypes: .thumbnail
        )
        thumbnailTask = request
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, _ in
            guard let self, self.thumbnailTask === request, let thumbnail else { return }
            DispatchQueue.main.async { completion(thumbnail.uiImage) }
        }
    }
    
    private func loadThumbnail(for item: FileItem) {
        generateThumbnail(for: item.url) { [weak self] image in
            self?.iconView.image = image
            self?.iconView.contentMode = .scaleAspectFit
        }
    }
    
    private func loadFolderThumbnail(for item: FileItem) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            
            let contents = try? FileStoreService.shared.contents(of: item.url)
            let mediaItem = contents?.first(where: {
                !$0.isDirectory && ["jpg","jpeg","png","heic","gif","webp","mp4","mov","m4v"].contains($0.url.pathExtension.lowercased())
            })
            
            guard let mediaItem else { return }
            
            self.generateThumbnail(for: mediaItem.url) { [weak self] image in
                guard let self else { return }
                
                let overlay                = UIImageView(image: image)
                overlay.contentMode        = .scaleAspectFill
                overlay.clipsToBounds      = true
                overlay.layer.cornerRadius = 3
                overlay.translatesAutoresizingMaskIntoConstraints = false
                self.iconView.addSubview(overlay)
                
                NSLayoutConstraint.activate([
                    overlay.centerXAnchor.constraint(equalTo: self.iconView.centerXAnchor),
                    overlay.centerYAnchor.constraint(equalTo: self.iconView.centerYAnchor, constant: 6),
                    overlay.widthAnchor.constraint(equalTo: self.iconView.widthAnchor, multiplier: 0.8),
                    overlay.heightAnchor.constraint(equalTo: self.iconView.heightAnchor, multiplier: 0.6),
                ])
            }
        }
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnailTask               = nil
        iconView.subviews.forEach   { $0.removeFromSuperview() }
        iconView.image              = nil
        iconView.contentMode        = .center
    }
}
