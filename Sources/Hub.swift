import Foundation

/// Connects the parts of the app.
final class Hub {
    static let shared = Hub()
    let status = Status()
    private lazy var pendant = Pendant(status: status)
    private var started = false
    private var lastBeat = Date.distantPast
    private var lastKick = Date.distantPast

    func start() {
        guard !started else { return }
        started = true
        Log.write("app start, build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")")
        Uploader.shared.status = status
        pendant.onFileReady = {
            Uploader.shared.kick()
            Hub.shared.beat(force: false)
        }
        pendant.onLinkChange = { Hub.shared.beat(force: true) }
        pendant.onQuestion = { file in Uploader.shared.sendNow(file) }
        pendant.answerReady = { clip, done in Uploader.shared.answerReady(clip, completion: done) }
        pendant.onAlive = {
            // also in quiet times: tell the Mac mini that the app is alive, and try waiting uploads again
            Hub.shared.beat(force: false)
            DispatchQueue.main.async {
                if Date().timeIntervalSince(Hub.shared.lastKick) > 120 {
                    Hub.shared.lastKick = Date()
                    Uploader.shared.kick()
                }
            }
        }
        pendant.start()
        Uploader.shared.kick()
        beat(force: true)
    }

    /// Sends the status to the Mac mini. Without force: one time in 10 minutes at most.
    func beat(force: Bool) {
        DispatchQueue.main.async {
            if !force && Date().timeIntervalSince(self.lastBeat) < 600 { return }
            self.lastBeat = Date()
            Heartbeat.send(status: self.status)
        }
    }
}
