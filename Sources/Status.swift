import Combine
import Foundation

/// What the status screen and the status message to the Mac mini show.
final class Status: ObservableObject {
    @Published var link = "starting"
    @Published var battery: Int?
    @Published var firmware = ""
    @Published var lastAudio: Date?
    @Published var pendingFiles = 0
    @Published var uploadedFiles = 0
    @Published var lastUpload: Date?
    @Published var lastError = ""
    @Published var signatureEnd: Date? = Signature.firstEnd()
    @Published var serverSet = Settings.baseURL != nil

    /// Change values from any thread.
    func set(_ change: @escaping (Status) -> Void) {
        if Thread.isMainThread { change(self) } else { DispatchQueue.main.async { change(self) } }
    }
}

enum Signature {
    /// End date of the permission file that came with the install. A later renewal does not change this file,
    /// so this is only the first end date. Nil in a store build.
    static func firstEnd() -> Date? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              let key = text.range(of: "<key>ExpirationDate</key>"),
              let open = text.range(of: "<date>", range: key.upperBound..<text.endIndex),
              let close = text.range(of: "</date>", range: open.upperBound..<text.endIndex) else { return nil }
        return ISO8601DateFormatter().date(from: String(text[open.upperBound..<close.lowerBound]))
    }
}
