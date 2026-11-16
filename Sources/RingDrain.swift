import Foundation

/// Reads the audio that the pendant stored in its own memory ("ring") while no phone was connected.
/// Firmware 3.0.21 can free a record as soon as it sent it. So each received byte goes to a file at once,
/// and nothing is kept only in memory. The Mac mini decodes the records later.
///
/// Wire format (all numbers big-endian), on the storage control characteristic:
///   send [0x10]                      -> INFO  [0x02][read u64][write u64][capacity u32][dropped u64][record bytes u16]
///   send [0x11][start u64]           -> DATA  [0x03][raw bytes, not aligned to records] ... then DONE [0x04][status][next u64]
///   send [0x12][next u64]            -> ACK   [0x01][status]   (the pendant can free the records)
///   send [0x03]                      -> stop a read
/// One record is 444 bytes. Files are cut at a whole number of records.
///
/// The Omi app can be connected to the same pendant on the same iPhone at the same time. iOS gives each
/// notification to both apps. So when the Omi app starts a read, this class stores that data too ("passive").
/// It does not release anything in that case; the Omi app does that for its own read.
/// Use from the Bluetooth queue only.
final class RingDrain {
    private enum Phase { case idle, waitInfo, reading, waitAdvance }
    private var phase = Phase.idle
    private let recordBytes = 444
    private let partLimit = 444 * 8192            // about 3.6 MB for each file
    var send: ((Data) -> Void)?
    var onPartReady: (() -> Void)?
    var deviceTag = "omi"
    var clockValid = false
    private var startSeq: UInt64 = 0
    private var totalBytes = 0
    private var partBytes = 0
    private var part = 0
    private var stamp = 0
    private var handle: FileHandle?
    private var partURL: URL?
    private var lastEvent = Date.distantPast
    private var infoTries = 0
    private var passive = false

    var isBusy: Bool { phase != .idle }

    func begin() {
        guard phase == .idle || phase == .waitInfo else { return }
        phase = .waitInfo
        infoTries += 1
        lastEvent = Date()
        send?(Data([0x10]))
    }

    func handle(_ value: Data) {
        guard let kind = value.first else { return }
        lastEvent = Date()
        switch kind {
        case 0x02: info(value)
        case 0x03:
            if phase != .reading && !passive {      // another app started this read: keep a copy
                passive = true
                totalBytes = 0
                partBytes = 0
                part = 0
                stamp = Int(Date().timeIntervalSince1970)
                Log.write("ring: data from a read of another app. Passive copy starts.")
            }
            store(value.dropFirst())
        case 0x04:
            if phase == .reading {
                done(value)
            } else if passive {
                closePart()
                passive = false
                Log.write("ring: passive copy ended, \(totalBytes / recordBytes) records")
            }
        case 0x01: answer(value)
        default: break
        }
    }

    /// Call one time each second.
    func tick() {
        let idle = Date().timeIntervalSince(lastEvent)
        switch phase {
        case .waitInfo:
            if idle > 5 {
                if infoTries < 5 { begin() } else { phase = .idle }
            }
        case .reading:
            if idle > 15 {
                Log.write("ring: no data for 15 s. Stop. The saved part stays.")
                send?(Data([0x03]))
                closePart()
                phase = .idle
            }
        case .waitAdvance:
            if idle > 5 { phase = .idle }
        case .idle:
            if passive && idle > 15 {
                closePart()
                passive = false
            }
        }
    }

    func linkLost() {
        closePart()
        phase = .idle
        passive = false
        infoTries = 0
    }

    private func number(_ data: Data, at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 { value = (value << 8) | UInt64(data[data.startIndex + offset + i]) }
        return value
    }

    private func bytes(_ value: UInt64) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian) { Array($0) }
    }

    private func info(_ value: Data) {
        guard phase == .waitInfo, value.count >= 31 else { return }
        let read = number(value, at: 1)
        let write = number(value, at: 9)
        let dropped = number(value, at: 21)
        Log.write("ring: read \(read), write \(write), overwritten \(dropped)")
        guard write > read else {
            phase = .idle
            return
        }
        if passive {            // do not mix two reads in one file
            closePart()
            passive = false
        }
        startSeq = read
        totalBytes = 0
        partBytes = 0
        part = 0
        stamp = Int(Date().timeIntervalSince1970)
        phase = .reading
        send?(Data([0x11] + bytes(read)))
    }

    private func store(_ payload: Data) {
        var rest = payload
        while !rest.isEmpty {
            if handle == nil { openPart() }
            guard let handle = handle else { return }
            let piece = rest.prefix(partLimit - partBytes)
            do {
                try handle.write(contentsOf: piece)
            } catch {
                Log.write("ring: write failed: \(error.localizedDescription)")
            }
            partBytes += piece.count
            totalBytes += piece.count
            rest = rest.dropFirst(piece.count)
            if partBytes >= partLimit { closePart() }
        }
    }

    private func done(_ value: Data) {
        closePart()
        guard value.count >= 10 else {
            Log.write("ring: short end message. No release.")
            phase = .idle
            return
        }
        let status = value[value.startIndex + 1]
        let next = number(value, at: 2)
        let records = UInt64(totalBytes / recordBytes)
        if status == 0, totalBytes % recordBytes == 0, next == startSeq + records {
            Log.write("ring: \(records) records are in files. Release up to \(next).")
            phase = .waitAdvance
            send?(Data([0x12] + bytes(next)))
        } else {
            Log.write("ring: end not clean (status \(status), bytes \(totalBytes), next \(next), start \(startSeq)). The files stay. No release.")
            phase = .idle
        }
    }

    private func answer(_ value: Data) {
        let code = value.count > 1 ? Int(value[value.startIndex + 1]) : -1
        switch phase {
        case .waitAdvance:
            Log.write("ring: release answer \(code)")     // 0 = done, 10 = the pendant released it before
            phase = .idle
        case .reading:
            if code != 0 {
                Log.write("ring: read refused, code \(code)")
                closePart()
                phase = .idle
            }
        default:
            break
        }
    }

    private func openPart() {
        let name = passive
            ? String(format: "ringp_%@_%d_rtc%d_p%04d.ringraw", deviceTag, stamp, clockValid ? 1 : 0, part)
            : String(format: "ring_%@_%d_%llu_rtc%d_p%04d.ringraw", deviceTag, stamp, startSeq, clockValid ? 1 : 0, part)
        let file = Paths.recording.appendingPathComponent(name)
        FileManager.default.createFile(
            atPath: file.path, contents: nil,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        handle = try? FileHandle(forWritingTo: file)
        partURL = file
        partBytes = 0
        if handle == nil { Log.write("ring: cannot open \(name)") }
    }

    private func closePart() {
        guard let handle = handle, let file = partURL else { return }
        try? handle.synchronize()
        try? handle.close()
        self.handle = nil
        partURL = nil
        if partBytes == 0 {
            try? FileManager.default.removeItem(at: file)
        } else {
            try? FileManager.default.moveItem(at: file, to: Paths.outbox.appendingPathComponent(file.lastPathComponent))
            part += 1
            onPartReady?()
        }
    }
}
