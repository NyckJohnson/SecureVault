import Foundation

/// Name validation and the " 1", " 2" conflict rule shared by every store operation that names an item.
enum VaultNaming {
    /// The extension new documents get.
    static let documentExtension = "rtf"

    /// Throws `.invalidName` for an empty name or one containing "/".
    static func validate(_ name: String) throws {
        guard !name.isEmpty, !name.contains("/") else { throw VaultStoreError.invalidName }
    }

    /// `validate(_:)` plus `.invalidName` for a name starting with "." — for names the user types (new
    /// folder, new document, rename). Dot names are hidden from listings, and a root ".trash" would
    /// become the trash.
    static func validateUserName(_ name: String) throws {
        try validate(name)
        guard !name.hasPrefix(".") else { throw VaultStoreError.invalidName }
    }

    /// `name` with ".rtf" added unless it already ends in it (any case).
    static func documentName(for name: String) -> String {
        name.lowercased().hasSuffix("." + documentExtension) ? name : name + "." + documentExtension
    }

    /// `name` if it is free, otherwise the first free "<base> N.<ext>" (N = 1, 2, …).
    ///
    /// A trailing " N" already in the base is dropped first, so a copy of "a 1.txt" becomes "a 2.txt",
    /// not "a 1 1.txt" (the rule earlier app versions used). A name without an extension gets the number
    /// at the end.
    static func resolvedName(for name: String, isTaken: (String) -> Bool) -> String {
        guard isTaken(name) else { return name }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        let strippedBase: String
        if let range = base.range(of: #" \d+$"#, options: .regularExpression), range.lowerBound > base.startIndex {
            strippedBase = String(base[base.startIndex..<range.lowerBound])
        } else {
            strippedBase = base
        }
        var counter = 1
        while true {
            let candidate = ext.isEmpty ? "\(strippedBase) \(counter)" : "\(strippedBase) \(counter).\(ext)"
            if !isTaken(candidate) { return candidate }
            counter += 1
        }
    }  // coverage-exempt: end of a function whose loop only exits by return
}
