//
//  RecentlyDeleted.swift
//  KoalaTVault
//
//  Created by Nicholas Johnson on 7/24/26.
//

import UIKit

final class LegacyRecentlyDeletedViewController: UIViewController, AlertPresenting {
    private let vaultStore: any VaultStoring
    private var items: [VaultItem] = []
    private var tableView: UITableView!

    /// - Parameter vaultStore: the app's vault store, which holds the trash.
    init(vaultStore: any VaultStoring) {
        self.vaultStore = vaultStore
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Recently Deleted"
        view.backgroundColor = .systemBackground
        setupTableView()
        setupNavigationBar()
        loadItems()
    }

    private func setupTableView() {
        tableView = UITableView(frame: view.bounds, style: .insetGrouped)
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        tableView.accessibilityIdentifier = "recentlyDeleted.list"
        view.addSubview(tableView)
    }

    private func setupNavigationBar() {
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Empty Trash",
            style: .plain,
            target: self,
            action: #selector(emptyTrash)
        )
        navigationItem.rightBarButtonItem?.tintColor = .systemRed
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "recentlyDeleted.emptyTrashButton"
    }

    private func loadItems() {
        Task {
            do {
                // Most recently deleted first.
                items = try await vaultStore.trashContents().sorted {
                    ($0.deletedAt ?? $0.dateModified) > ($1.deletedAt ?? $1.dateModified)
                }
            } catch {
                items = []
                showError(error)
            }
            tableView.reloadData()
            tableView.backgroundView = items.isEmpty ? emptyStateLabel() : nil
            navigationItem.rightBarButtonItem?.isEnabled = !items.isEmpty
        }
    }

    private func emptyStateLabel() -> UILabel {
        let label = UILabel()
        label.text = "No recently deleted files"
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .body)
        label.accessibilityIdentifier = "recentlyDeleted.emptyStateLabel"
        return label
    }

    @objc private func emptyTrash() {
        let alert = UIAlertController(
            title: "Empty Trash?",
            message: "All recently deleted files will be permanently deleted.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Empty Trash", style: .destructive) { [weak self] _ in
            guard let self else { return }
            Task {
                // Best-effort by contract: it removes everything it can.
                await self.vaultStore.emptyTrash()
                self.loadItems()
            }
        })
        present(alert, animated: true)
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

// MARK: - UITableViewDataSource
extension LegacyRecentlyDeletedViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        let item = items[indexPath.row]
        var config = cell.defaultContentConfiguration()
        config.text = item.name
        let daysLeft = 30 - Int(Date().timeIntervalSince(item.deletedAt ?? item.dateModified) / 86400)
        config.secondaryText = "Deletes in \(max(0, daysLeft)) day\(daysLeft == 1 ? "" : "s")"
        let (icon, tint) = Self.iconImageAndTint(for: item)
        config.image = icon
        config.imageProperties.tintColor = tint
        cell.contentConfiguration = config
        cell.accessibilityIdentifier = "recentlyDeleted.row.\(item.name)"
        return cell
    }
}

// MARK: - UITableViewDelegate
extension LegacyRecentlyDeletedViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let item = items[indexPath.row]
        let alert = UIAlertController(title: item.name, message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Restore", style: .default) { [weak self] _ in
            guard let self else { return }
            Task {
                do {
                    _ = try await self.vaultStore.restore(item)
                    self.loadItems()
                    NotificationCenter.default.post(name: .fileRestored, object: nil)
                } catch {
                    self.showError(error)
                }
            }
        })
        alert.addAction(UIAlertAction(title: "Delete Permanently", style: .destructive) { [weak self] _ in
            guard let self else { return }
            Task {
                do {
                    try await self.vaultStore.deletePermanently(item)
                    self.loadItems()
                } catch {
                    self.showError(error)
                }
            }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = tableView.cellForRow(at: indexPath)
        }
        present(alert, animated: true)
    }
}
