//
//  AppDelegate.swift
//  KoalaTVault
//
//  Created by Nicholas Johnson on 5/10/26.
//

import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {



    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
#if DEBUG
        if CommandLine.arguments.contains("--uitesting") {
            PreferencesService.shared.hasCompletedSetup = false
            AuthService.shared.lockMode = .none
            try? AuthService.shared.removePassword()
            UIView.setAnimationsEnabled(false)
            try? FileSystem.shared.emptyTrash(for: .root)
            CryptoService.shared.wipeKey()
            let rootContents = (try? FileManager.default.contentsOfDirectory(at: VaultDirectory.root.diskURL, includingPropertiesForKeys: nil)) ?? []
            rootContents.forEach { try? FileManager.default.removeItem(at: $0) }

            if let fileName = ProcessInfo.processInfo.environment["UITEST_SEED_FILE_NAME"] {
                let url = VaultDirectory.root.diskURL.appendingPathComponent(fileName)
                FileManager.default.createFile(atPath: url.path, contents: Data("uitest content".utf8))
            }

            if let countString = ProcessInfo.processInfo.environment["UITEST_SEED_FILE_COUNT"],
               let count = Int(countString) {
                for i in 0..<count {
                    let url = VaultDirectory.root.diskURL.appendingPathComponent("uitest-seed-\(i).txt")
                    FileManager.default.createFile(atPath: url.path, contents: Data("uitest content".utf8))
                }
            }

            if let password = ProcessInfo.processInfo.environment["UITEST_PASSWORD"] {
                try? AuthService.shared.createPassword(password)
                AuthService.shared.lockMode = .password
                AuthService.shared.hasAuthenticated = true
                PreferencesService.shared.hasCompletedSetup = true
            }
        }
#endif
        return true
    }

    // MARK: UISceneSession Lifecycle

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // Called when a new scene session is being created.
        // Use this method to select a configuration to create the new scene with.
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        // Called when the user discards a scene session.
        // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
        // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
    }


}

