import Foundation

/// Folders of the app. They are in Documents, so the Files app and a Mac can see them.
enum Paths {
    static let documents: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let recording: URL = folder("recording")   // the file that is open now
    static let outbox: URL = folder("outbox")         // complete files that wait for the upload

    private static func folder(_ name: String) -> URL {
        let url = documents.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // The app must write while the iPhone is locked.
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        return url
    }
}
