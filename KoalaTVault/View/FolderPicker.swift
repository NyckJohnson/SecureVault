//
//  FolderPickerViewController.swift
//  KoalaTVault
//
//  Created by Nicholas Johnson on 7/10/26.
//

import UIKit

protocol FolderPickerDelegate: AnyObject {
    func folderPicker(_ picker: FolderPickerViewController, didSelectFolder directory: VaultDirectory)
}

final class FolderPickerViewController: UIViewController {
    
    weak var delegate: FolderPickerDelegate?
    private let rootDirectory: VaultDirectory
    private let currentDirectory: VaultDirectory
    private var items: [VaultItem] = []
    private var tableView: UITableView!
    
    init(rootDirectory: VaultDirectory, currentDirectory: VaultDirectory) {
        self.rootDirectory = rootDirectory
        self.currentDirectory = currentDirectory
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemBackground

        let cancelButton = UIBarButtonItem(
            title: "Cancel", style: .plain, target: self, action: #selector(cancel)
        )
        let moveHereButton = UIBarButtonItem(
            title: "Move Here", style: .done, target: self, action: #selector(moveHere)
        )
        // for ui tests
        cancelButton.accessibilityIdentifier   = "folderPicker.cancelButton"
        moveHereButton.accessibilityIdentifier = "folderPicker.moveHereButton"
        navigationItem.leftBarButtonItem = cancelButton
        navigationItem.rightBarButtonItem = moveHereButton

        tableView = UITableView(frame: view.bounds, style: .plain)
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "FolderCell")
        tableView.accessibilityIdentifier = "folderPicker.folderList"
        view.addSubview(tableView)

        loadContents()
    }
    
    private func loadContents() {
        let all = (try? FileSystem.shared.contents(of: currentDirectory)) ?? []
        items = all.filter { $0.isDirectory }
        tableView.reloadData()
    }
    
    @objc private func cancel() {
        dismiss(animated: true)
    }
    
    @objc private func moveHere() {
        // Tell the delegate after the sheet is gone, so it can present an error alert.
        let delegate = delegate
        let directory = currentDirectory
        dismiss(animated: true) {
            delegate?.folderPicker(self, didSelectFolder: directory)
        }
    }
}

extension FolderPickerViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "FolderCell", for: indexPath)
        var config = cell.defaultContentConfiguration()
        config.text = items[indexPath.row].name
        config.image = UIImage(systemName: "folder.fill")
        config.imageProperties.tintColor = UIColor.systemYellow
        cell.contentConfiguration = config
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityIdentifier = "folderPicker.row.\(items[indexPath.row].name)"
        return cell
    }
}

extension FolderPickerViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let folder = items[indexPath.row]
        let next = FolderPickerViewController(
            rootDirectory: rootDirectory,
            currentDirectory: VaultDirectory(name: folder.name, diskURL: folder.diskURL, rootURL: currentDirectory.rootURL)
        )
        next.delegate = delegate
        navigationController?.pushViewController(next, animated: true)
    }
}
