import CryptoKit
import Foundation

/// Sends the files in the outbox to the Mac mini. Wi-Fi only.
/// A file is deleted on the iPhone only after the Mac mini sends back the same SHA-256.
///
/// The app sends each file itself, at once, while it runs. It runs as long as the pendant sends audio.
/// Up to build 8 the files went through a background session of iOS. Two faults came from that (17 Nov 2026):
///   - iOS held the uploads for hours while the iPhone was locked (iOS decides when such an upload starts);
///   - after such a pause one file got many upload tasks, and the app sent each file 30 to 170 times.
/// Now one serial queue decides, and a file has one upload at a time.
final class Uploader: NSObject, URLSessionDataDelegate {
    static let shared = Uploader()
    var status: Status?
    var backgroundCompletion: (() -> Void)?
    var retryDelay: TimeInterval = 120                              // a file that was not confirmed waits this long
    private let queue = DispatchQueue(label: "courier.upload")      // all upload decisions, one at a time
    private let lock = NSLock()
    private var replies = [Int: Data]()
    private var kickWaits = false
    // The values below are used on `queue` only.
    private var inWork = Set<String>()                              // file names with an upload in work
    private var notBefore = [String: Date]()
    private var failures = 0                                        // uploads in a row that were not confirmed
    private var holdUntil = Date.distantPast                        // no new upload before this time
    private var legacyRetired = false
    private let maxParallel = 2

    private lazy var direct: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.allowsCellularAccess = false            // no mobile data
        config.allowsExpensiveNetworkAccess = false    // no personal hotspot
        config.allowsConstrainedNetworkAccess = true
        config.waitsForConnectivity = false            // no Wi-Fi: fail at once, try again later
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config)
    }()

    #if os(iOS)
    /// The background session of build 8 and older. No new upload starts here.
    private lazy var legacy: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.mk07.omicourier.upload")
        config.allowsCellularAccess = false
        config.allowsExpensiveNetworkAccess = false
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Stops the uploads that an older build left in iOS. Their files stay in the outbox and go the direct way.
    private func retireLegacy() {
        legacy.getAllTasks { tasks in
            if !tasks.isEmpty { Log.write("old upload tasks stopped: \(tasks.count)") }
            tasks.forEach { $0.cancel() }
        }
    }
    #endif

    private lazy var fast: URLSession = {
        let config = URLSessionConfiguration.ephemeral      // small question clips: at once, mobile data permitted
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    /// Sends one small file at once. If this fails, the file goes to the outbox and takes the usual way.
    func sendNow(_ file: URL) {
        let name = file.lastPathComponent
        let fallback = { try? FileManager.default.moveItem(at: file, to: Paths.outbox.appendingPathComponent(name)); self.kick() }
        guard let url = Settings.url(name), let data = try? Data(contentsOf: file) else { _ = fallback(); return }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(Uploader.hex(SHA256.hash(data: data)), forHTTPHeaderField: "X-Sha256")
        fast.uploadTask(with: request, from: data) { _, response, error in
            if error == nil, (response as? HTTPURLResponse)?.statusCode == 200 {
                try? FileManager.default.removeItem(at: file)
            } else {
                Log.write("question: fast upload failed, usual way")
                _ = fallback()
            }
        }.resume()
    }

    private lazy var quick: URLSession = {
        let config = URLSessionConfiguration.ephemeral      // signal requests: small, with a short time limit
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 8
        return URLSession(configuration: config)
    }()

    /// Asks the Mac mini for signals: answers that are ready, a test vibration, the vibration signs.
    func signal(_ query: String, completion: @escaping ([String: Any]?) -> Void) {
        guard let url = Settings.url("_signal?" + query) else { completion(nil); return }
        quick.dataTask(with: url) { data, _, _ in
            var reply: [String: Any]?
            if let data = data, let object = try? JSONSerialization.jsonObject(with: data) { reply = object as? [String: Any] }
            completion(reply)
        }.resume()
    }

    static func outboxFiles() -> [URL] {
        let list = (try? FileManager.default.contentsOfDirectory(at: Paths.outbox, includingPropertiesForKeys: nil)) ?? []
        return list.filter { $0.pathExtension == "bin" || $0.pathExtension == "ringraw" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Starts the upload of waiting files. Safe to call often and from any thread.
    func kick() {
        lock.lock()
        if kickWaits { lock.unlock(); return }
        kickWaits = true
        lock.unlock()
        queue.async {
            self.lock.lock()
            self.kickWaits = false
            self.lock.unlock()
            self.fill()
        }
    }

    /// Gives an upload to each waiting file, oldest first, two at a time. Runs on `queue`.
    private func fill() {
        #if os(iOS)
        if !legacyRetired {
            legacyRetired = true
            retireLegacy()
        }
        #endif
        let files = Uploader.outboxFiles()
        let count = files.count
        status?.set { $0.pendingFiles = count }
        let now = Date()
        if holdUntil > now { return }                           // after a fault: wait, then try again
        for file in files {
            if inWork.count >= maxParallel { break }
            let name = file.lastPathComponent
            if inWork.contains(name) { continue }
            if let wait = notBefore[name], wait > now { continue }
            guard let url = Settings.url(name) else { break }       // no server address yet: the files wait
            guard let data = try? Data(contentsOf: file), !data.isEmpty else { continue }
            let sent = Uploader.hex(SHA256.hash(data: data))
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue(sent, forHTTPHeaderField: "X-Sha256")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            inWork.insert(name)
            direct.uploadTask(with: request, from: data) { [weak self] body, response, error in
                self?.queue.async { self?.finished(name, sent: sent, body: body, response: response, error: error) }
            }.resume()
        }
    }

    /// The end of one upload. Runs on `queue`.
    private func finished(_ name: String, sent: String, body: Data?, response: URLResponse?, error: Error?) {
        inWork.remove(name)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if error == nil, code == 200, Uploader.confirms(body, sent) {
            try? FileManager.default.removeItem(at: Paths.outbox.appendingPathComponent(name))   // the Mac mini has the same bytes
            notBefore[name] = nil
            failures = 0
            holdUntil = Date.distantPast
            status?.set {
                $0.lastUpload = Date()
                $0.uploadedFiles += 1
                $0.lastError = ""
            }
        } else {
            let text = error?.localizedDescription ?? "server answer \(code)"
            failures += 1
            notBefore[name] = Date().addingTimeInterval(retryDelay)
            // no Wi-Fi or no server: do not try each waiting file. Wait 15 s, 30 s, 60 s, then 2 minutes each time.
            let pause = min(15.0 * pow(2.0, Double(min(failures, 6) - 1)), max(retryDelay, 1.0))
            holdUntil = Date().addingTimeInterval(pause)
            status?.set { $0.lastError = text }
            if failures == 1 || failures % 20 == 0 {
                Log.write("upload of \(name) not confirmed: \(text) (faults in a row: \(failures))")
            }
            queue.asyncAfter(deadline: .now() + pause + 0.5) { [weak self] in self?.fill() }
        }
        fill()
    }

    /// True when the reply of the Mac mini is {"ok": true, "sha256": <the SHA-256 that the app sent>}.
    static func confirms(_ reply: Data?, _ sent: String) -> Bool {
        guard let reply = reply, !sent.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: reply), let json = object as? [String: Any] else { return false }
        return (json["ok"] as? Bool) == true && (json["sha256"] as? String) == sent
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    // ---- the old background session (build 8 and older): only the ends of its uploads arrive here

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
        if error == nil, code == 200, Uploader.confirms(reply, sent) {
            try? FileManager.default.removeItem(at: Paths.outbox.appendingPathComponent(name))   // the Mac mini has the same bytes
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
