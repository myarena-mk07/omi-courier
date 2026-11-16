import Foundation

/// Writes Opus packets in the phone file format of Omi: [UInt32 little-endian length][packet], again and again.
/// One file holds one continuous run of audio. The file name holds the real start time (Unix seconds).
/// Use from one queue only.
final class SegmentWriter {
    private var handle: FileHandle?
    private var url: URL?
    private var startedAt = Date.distantPast
    private var packets = 0
    private let maxSeconds: TimeInterval = 60
    var deviceTag = "omi"
    var onClosed: (() -> Void)?

    func append(_ packet: Data, at time: Date, newRun: Bool) {
        if handle == nil || newRun || time.timeIntervalSince(startedAt) >= maxSeconds {
            close()
            open(at: time)
        }
        guard let handle = handle else { return }
        var length = UInt32(packet.count).littleEndian
        var record = Data(bytes: &length, count: 4)
        record.append(packet)
        do {
            try handle.write(contentsOf: record)
            packets += 1
        } catch {
            Log.write("write failed: \(error.localizedDescription)")
            close()
        }
    }

    private func open(at time: Date) {
        let name = String(format: "audio_%@_opus_fs320_16000_1_fs320_%.3f.bin", deviceTag, time.timeIntervalSince1970)
        let file = Paths.recording.appendingPathComponent(name)
        FileManager.default.createFile(
            atPath: file.path, contents: nil,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        handle = try? FileHandle(forWritingTo: file)
        url = file
        startedAt = time
        packets = 0
        if handle == nil { Log.write("cannot open \(name)") }
    }

    /// Closes the open file and moves it to the outbox.
    func close() {
        guard let handle = handle, let file = url else { return }
        try? handle.synchronize()
        try? handle.close()
        self.handle = nil
        url = nil
        if packets == 0 {
            try? FileManager.default.removeItem(at: file)
        } else {
            try? FileManager.default.moveItem(at: file, to: Paths.outbox.appendingPathComponent(file.lastPathComponent))
            onClosed?()
        }
    }

    /// Files from an earlier run of the app that did not close in the usual way. Their audio is good.
    static func recoverLeftovers() {
        let fm = FileManager.default
        for file in (try? fm.contentsOfDirectory(at: Paths.recording, includingPropertiesForKeys: nil)) ?? [] {
            let attributes = try? fm.attributesOfItem(atPath: file.path)
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            if size > 4 {
                try? fm.moveItem(at: file, to: Paths.outbox.appendingPathComponent(file.lastPathComponent))
            } else {
                try? fm.removeItem(at: file)
            }
        }
    }
}
