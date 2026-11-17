import Foundation

// usage: harness <folder> <base url> <scenario> [files]
let scenario = CommandLine.arguments[3]
let n = CommandLine.arguments.count > 4 ? Int(CommandLine.arguments[4])! : 300
let fm = FileManager.default
try? fm.createDirectory(at: Paths.outbox, withIntermediateDirectories: true)
let status = Status()
Uploader.shared.status = status
var made = 0
func makeFile() {
    made += 1
    let name = String(format: "audio_omitest_opus_fs320_16000_1_fs320_%.3f.bin", 1794900000.0 + Double(made) * 60.0)
    var bytes = [UInt8](repeating: 0, count: Int.random(in: 50_000...250_000))
    for i in stride(from: 0, to: bytes.count, by: 97) { bytes[i] = UInt8.random(in: 0...255) }
    let tmp = Paths.root.appendingPathComponent("tmp_" + name)
    try! Data(bytes).write(to: tmp)
    try! fm.moveItem(at: tmp, to: Paths.outbox.appendingPathComponent(name))
}
func pending() -> Int { Uploader.outboxFiles().count }
func waitEmpty(_ seconds: Double, kickEach: Double) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if pending() == 0 { return true }
        Uploader.shared.kick()
        Thread.sleep(forTimeInterval: kickEach)
    }
    return pending() == 0
}
let t0 = Date()
switch scenario {
case "backlog":
    // a pause ended: n files wait. Then many parts of the app call kick() at the same time, and new files arrive.
    for _ in 0..<n { makeFile() }
    for _ in 0..<64 { DispatchQueue.global().async { for _ in 0..<50 { Uploader.shared.kick() } } }
    var extra = 0
    while pending() > 0 && Date().timeIntervalSince(t0) < 180 {
        if extra < 30 { makeFile(); extra += 1 }                 // new audio during the drain
        for _ in 0..<20 { Uploader.shared.kick() }
        Thread.sleep(forTimeInterval: 0.05)
    }
    Thread.sleep(forTimeInterval: 1.0)
    print("backlog: files made \(made) | still waiting \(pending()) | confirmed \(status.uploaded) | \(String(format: "%.1f", Date().timeIntervalSince(t0))) s | log lines \(Log.count) | last fault '\(status.fault)'")
case "down":
    // the server does not answer (or no Wi-Fi): the files stay, and the app tries seldom
    Uploader.shared.retryDelay = 4
    for _ in 0..<n { makeFile() }
    for _ in 0..<100 { Uploader.shared.kick(); Thread.sleep(forTimeInterval: 0.1) }      // 10 s of kicks
    print("down, after 10 s: still waiting \(pending()) of \(made) | confirmed \(status.uploaded) | log lines \(Log.count) | last fault '\(status.fault)'")
    print("READY-FOR-SERVER"); fflush(stdout)
    let ok = waitEmpty(90, kickEach: 1.0)                       // the test script starts the server now
    Thread.sleep(forTimeInterval: 1.0)
    print("down then up: empty \(ok) | confirmed \(status.uploaded) of \(made) | \(String(format: "%.1f", Date().timeIntervalSince(t0))) s | log lines \(Log.count)")
default:
    print("unknown scenario")
}
for line in Log.lines.prefix(4) { print("  log:", line) }
