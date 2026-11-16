import CryptoKit
import Foundation

/// Sends the files in the outbox to the Mac mini. Wi-Fi only. iOS continues the transfer when the app sleeps.
/// A file is deleted on the iPhone only after the Mac mini sends back the same SHA-256.
final class Uploader: NSObject, URLSessionDataDelegate {
    static let shared = Uploader()
    var status: Status?
    var backgroundCompletion: (() -> Void)?
    private let lock = NSLock()
    private var replies = [Int: Data]()
    private var notBefore = [String: Date]()

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.mk07.omicourier.upload")
        config.allowsCellularAccess = false            // no mobile data
        config.allowsExpensiveNetworkAccess = false    // no personal hotspot
        config.allowsConstrainedNetworkAccess = true
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.httpMaximumConnectionsPerHost = 2
        config.timeoutIntervalForResource = 14 * 24 * 3600
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    static func outboxFiles() -> [URL] {
        let list = (try? FileManager.default.contentsOfDirectory(at: Paths.outbox, includingPropertiesForKeys: nil)) ?? []
        return list.filter { $0.pathExtension == "bin" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Starts an upload for each waiting file that is not in work.
    func kick() {
        session.getAllTasks { [weak self] tasks in
            guard let self = self else { return }
            var active = Set(tasks.compactMap { $0.taskDescription })
            let files = Uploader.outboxFiles()
            self.status?.set { $0.pendingFiles = files.count }
            let now = Date()
            for file in files {
                if active.count >= 12 { break }
                let name = file.lastPathComponent
                if active.contains(name) { continue }
                self.lock.lock()
                let wait = self.notBefore[name]
                self.lock.unlock()
                if let wait = wait, wait > now { continue }
                guard let data = try? Data(contentsOf: file), !data.isEmpty,
                      let url = URL(string: Config.baseURL + "/" + name) else { continue }
                var request = URLRequest(url: url)
                request.httpMethod = "PUT"
                request.setValue(Uploader.hex(SHA256.hash(data: data)), forHTTPHeaderField: "X-Sha256")
                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                let task = self.session.uploadTask(with: request, fromFile: file)
                task.taskDescription = name
                task.resume()
                active.insert(name)
            }
        }
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        replies[dataTask.taskIdentifier, default: Data()].append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let reply = replies.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let name = task.taskDescription else { return }
        let code = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let sent = task.originalRequest?.value(forHTTPHeaderField: "X-Sha256") ?? ""
        var confirmed = false
        if error == nil, code == 200, let reply = reply, !sent.isEmpty,
           let object = try? JSONSerialization.jsonObject(with: reply), let json = object as? [String: Any],
           (json["ok"] as? Bool) == true, (json["sha256"] as? String) == sent {
            confirmed = true
        }
        if confirmed {
            try? FileManager.default.removeItem(at: Paths.outbox.appendingPathComponent(name))   // the Mac mini has the same bytes
            status?.set {
                $0.lastUpload = Date()
                $0.uploadedFiles += 1
                $0.lastError = ""
            }
        } else {
            let text = error?.localizedDescription ?? "server answer \(code)"
            lock.lock()
            notBefore[name] = Date().addingTimeInterval(120)
            lock.unlock()
            status?.set { $0.lastError = text }
            Log.write("upload of \(name) not confirmed: \(text)")
        }
        kick()
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.backgroundCompletion?()
            self.backgroundCompletion = nil
        }
    }
}
