import Foundation

// Stand-ins for the app parts that the uploader uses, so the real Sources/Uploader.swift runs on the Mac mini.
enum Paths {
    static var root = URL(fileURLWithPath: CommandLine.arguments[1])
    static var outbox: URL { root.appendingPathComponent("outbox") }
    static var documents: URL { root }
}
enum Settings {
    static var base: String? = CommandLine.arguments[2]
    static func url(_ lastPart: String) -> URL? { base.flatMap { URL(string: $0 + "/" + lastPart) } }
}
enum Log {
    static let lock = NSLock()
    static var lines = [String]()
    static func write(_ text: String) { lock.lock(); lines.append(text); lock.unlock() }
    static var count: Int { lock.lock(); defer { lock.unlock() }; return lines.count }
}
final class Status {
    private let q = DispatchQueue(label: "status")
    var pendingFiles = 0, uploadedFiles = 0, lastError = ""
    var lastUpload: Date?
    func set(_ change: @escaping (Status) -> Void) { q.sync { change(self) } }
    var uploaded: Int { q.sync { uploadedFiles } }
    var fault: String { q.sync { lastError } }
}
