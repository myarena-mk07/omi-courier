import Foundation

/// The address of the upload door on the private server. It is NOT in the app file.
/// It comes one time from Documents/config.json ({"base_url": "https://..."}), which a Mac copies to the iPhone,
/// or from a pasted setup text. The app keeps it in its own settings and deletes the file.
enum Settings {
    private static let key = "base_url"

    static var baseURL: String? {
        importFile()
        let value = UserDefaults.standard.string(forKey: key) ?? ""
        return value.isEmpty ? nil : value
    }

    static func url(_ lastPart: String) -> URL? {
        guard let base = baseURL else { return nil }
        return URL(string: base + "/" + lastPart)
    }

    /// Returns true when the text was a good address.
    @discardableResult
    static func accept(_ text: String) -> Bool {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        guard value.hasPrefix("https://"), URL(string: value) != nil, value.count < 400 else { return false }
        UserDefaults.standard.set(value, forKey: key)
        Log.write("server address set")
        return true
    }

    private static func importFile() {
        let file = Paths.documents.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        if let data = try? Data(contentsOf: file),
           let object = try? JSONSerialization.jsonObject(with: data), let json = object as? [String: Any],
           let text = json[key] as? String, accept(text) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
