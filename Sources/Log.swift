import Foundation

/// Small text log in Documents/courier.log, for fault finding.
enum Log {
    private static let queue = DispatchQueue(label: "courier.log")
    private static let url = Paths.documents.appendingPathComponent("courier.log")
    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func write(_ text: String) {
        let line = "\(stamp.string(from: Date())) \(text)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attributes?[.size] as? NSNumber, size.intValue > 1_000_000 {
                try? FileManager.default.removeItem(at: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
