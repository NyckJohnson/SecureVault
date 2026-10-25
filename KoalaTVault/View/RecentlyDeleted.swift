//
//  RecentlyDeleted.swift
//  KoalaTVault
//
//  Created by Nicholas Johnson on 7/24/26.
//

import UIKit

final class RecentlyDeletedViewController: UIViewController, ErrorPresenting {
    private var items: [VaultItem] = []
    private var tableView: UITableView!

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
        do {
            items = try FileSystem.shared.contentsOfTrash(for: .root)
        } catch {
            items = []
            showError(error)
        }
        tableView.reloadData()
        tableView.backgroundView = items.isEmpty ? emptyStateLabel() : nil
        navigationItem.rightBarButtonItem?.isEnabled = !items.isEmpty
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
            do {
                try FileSystem.shared.emptyTrash(for: .root)
                self.loadItems()
            } catch {
                self.showError(error)
            }
        })
        present(alert, animated: true)
    }
}

// MARK: - UITableViewDataSource
extension RecentlyDeletedViewController: UITableViewDataSource {
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
        config.image = FileIconProvider.icon(for: item)
        config.imageProperties.tintColor = FileIconProvider.iconColor(for: item)
        cell.contentConfiguration = config
        cell.accessibilityIdentifier = "recentlyDeleted.row.\(item.name)"
        return cell
    }
}

// MARK: - UITableViewDelegate
extension RecentlyDeletedViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let item = items[indexPath.row]
        let alert = UIAlertController(title: item.name, message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Restore", style: .default) { [weak self] _ in
            guard let self else { return }
            do {
                try FileSystem.shared.restoreFromTrash(item)
                self.loadItems()
                NotificationCenter.default.post(name: .fileRestored, object: nil)
            } catch {
                self.showError(error)
            }
        })
        alert.addAction(UIAlertAction(title: "Delete Permanently", style: .destructive) { [weak self] _ in
            guard let self else { return }
            do {
                try FileSystem.shared.permanentlyDelete(item)
                self.loadItems()
            } catch {
                self.showError(error)
            }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = tableView.cellForRow(at: indexPath)
        }
        present(alert, animated: true)
    }
}
