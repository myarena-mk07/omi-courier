import CoreBluetooth
import Foundation

/// The link to the Omi pendant. It takes the live audio and gives the Opus packets to the file writer.
/// iOS starts the app again for this link when the app is not in memory (state restoration).
final class Pendant: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let audioService = CBUUID(string: "19B10000-E8F2-537E-4F6C-D104768A1214")
    static let audioData = CBUUID(string: "19B10001-E8F2-537E-4F6C-D104768A1214")
    static let audioCodec = CBUUID(string: "19B10002-E8F2-537E-4F6C-D104768A1214")
    static let batteryLevel = CBUUID(string: "2A19")
    static let firmwareRevision = CBUUID(string: "2A26")
    static let timeWrite = CBUUID(string: "19B10031-E8F2-537E-4F6C-D104768A1214")
    static let storageControl = CBUUID(string: "30295781-4301-EABD-2904-2849ADFEAE43")
    static let storageStatus = CBUUID(string: "30295782-4301-EABD-2904-2849ADFEAE43")
    static let button = CBUUID(string: "23BA7925-0000-1000-7450-346EAC492E92")
    static let haptic = CBUUID(string: "CAB1AB96-2EA5-4F4D-BB56-874B72CFC984")

    private let queue = DispatchQueue(label: "courier.ble")
    private let status: Status
    private let writer = SegmentWriter()
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var timer: DispatchSourceTimer?
    private let ring = RingDrain()
    private var storage: CBCharacteristic?
    private var ringAsked = false

    // One audio notification is [packet number, 2 bytes little-endian][part number, 1 byte][Opus bytes].
    private var lastNumber: Int?
    private var lastPacketAt = Date.distantPast
    private var frame = Data()
    private var frameValid = false
    private var frameAt = Date()
    private var frameStartsRun = true
    private var nextStartsRun = true
    private var lastShown = Date.distantPast

    var onFileReady: (() -> Void)?
    var onLinkChange: (() -> Void)?
    var onAlive: (() -> Void)?
    var onQuestion: ((URL) -> Void)?

    // A question for the assistant: double tap on the pendant starts it, one tap ends it (20 s at most).
    // Do not hold the button: the firmware switches the pendant off after 3 seconds.
    private var hapticItem: CBCharacteristic?
    private var askFrames: [Data] = []
    private var askStart: Date?
    private let askMaxSeconds: TimeInterval = 120
    // Vibration signs. One step is [pulse, time to the start of the next pulse in ms]. The pendant knows the
    // pulses 1, 2 and 3 (short, medium, long). The Mac mini can send other signs, so a change needs no new app.
    private static let defaultSigns: [String: [[Int]]] = [
        "start": [[3, 0]],                           // one long: speak now
        "end": [[3, 750], [3, 0]],                   // two long: question sent
        "answer": [[3, 750], [3, 750], [3, 0]],      // three long: the answer is in Telegram
    ]
    private var signs = Pendant.loadSigns()
    private var waiting: [String: Date] = [:]        // question clips that wait for an answer
    private var listenUntil = Date.distantPast       // the app asks the Mac mini for signals until this time
    private var lastPoll = Date.distantPast
    private var lastWake = Date.distantPast
    private var pollBusy = false
    private var lastTestID: Int64 = 0
    private var playedReport: String?
    private var buzzFreeAt = Date.distantPast
    private var hapticConfirmed = 0
    private var hapticFailed = 0
    var signal: ((String, @escaping ([String: Any]?) -> Void) -> Void)?

    private static func loadSigns() -> [String: [[Int]]] {
        var result = defaultSigns
        for (name, value) in UserDefaults.standard.dictionary(forKey: "signs") ?? [:] {
            if let steps = value as? [[Int]], !steps.isEmpty { result[name] = steps }
        }
        return result
    }

    init(status: Status) {
        self.status = status
        super.init()
    }

    func start() {
        guard central == nil else { return }
        writer.onClosed = { [weak self] in self?.onFileReady?() }
        ring.onPartReady = { [weak self] in self?.onFileReady?() }
        ring.send = { [weak self] command in
            guard let self = self, let pendant = self.peripheral, let control = self.storage else { return }
            pendant.writeValue(command, for: control, type: .withResponse)
        }
        queue.sync {
            SegmentWriter.recoverLeftovers()
            listenUntil = Date().addingTimeInterval(600)
        }
        central = CBCentralManager(delegate: self, queue: queue, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "omi-courier-central",
            CBCentralManagerOptionShowPowerAlertKey: false,
        ])
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.idleCheck() }
        timer.resume()
        self.timer = timer
    }

    private func show(_ text: String) {
        status.set { $0.link = text }
        onLinkChange?()
    }

    // MARK: central

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let list = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral], let found = list.first {
            peripheral = found
            found.delegate = self
            Log.write("iOS started the app again for the pendant")
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            show("Bluetooth is not ready")
            return
        }
        if peripheral == nil, let saved = UserDefaults.standard.string(forKey: "pendant"), let id = UUID(uuidString: saved) {
            peripheral = central.retrievePeripherals(withIdentifiers: [id]).first
        }
        if peripheral == nil {
            peripheral = central.retrieveConnectedPeripherals(withServices: [Pendant.audioService]).first
        }
        if let known = peripheral {
            known.delegate = self
            if known.state == .connected {
                show("connected")
                known.discoverServices(nil)
            } else {
                show("waiting for the pendant")
                central.connect(known, options: nil)     // no time limit: iOS connects when the pendant is near
            }
        } else {
            show("searching for the pendant")
            central.scanForPeripherals(withServices: [Pendant.audioService], options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: "pendant")
        show("connecting")
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Log.write("connected")
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: "pendant")
        writer.deviceTag = "omi" + peripheral.identifier.uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        ring.deviceTag = writer.deviceTag
        storage = nil
        ringAsked = false
        lastNumber = nil
        frameValid = false
        nextStartsRun = true
        show("connected")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Log.write("connect failed: \(error?.localizedDescription ?? "-")")
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Log.write("disconnected: \(error?.localizedDescription ?? "-")")
        if askStart != nil { endQuestion() }
        flushFrame()
        writer.close()
        ring.linkLost()
        storage = nil
        nextStartsRun = true
        show("waiting for the pendant")
        central.connect(peripheral, options: nil)
    }

    // MARK: pendant

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for item in service.characteristics ?? [] {
            if item.uuid == Pendant.audioData {
                // Firmware 3.0.21 discards audio while a phone is connected and not subscribed. Subscribe at once.
                peripheral.setNotifyValue(true, for: item)
                Log.write("audio subscribed, packet room \(peripheral.maximumWriteValueLength(for: .withoutResponse) + 3)")
            } else if item.uuid == Pendant.timeWrite {
                // The pendant needs the time for the audio that it stores when no phone is near.
                var seconds = UInt32(Date().timeIntervalSince1970).littleEndian
                peripheral.writeValue(Data(bytes: &seconds, count: 4), for: item, type: .withResponse)
            } else if item.uuid == Pendant.storageControl {
                storage = item
                peripheral.setNotifyValue(true, for: item)
            } else if item.uuid == Pendant.storageStatus {
                peripheral.readValue(for: item)
            } else if item.uuid == Pendant.button {
                peripheral.setNotifyValue(true, for: item)
            } else if item.uuid == Pendant.haptic {
                hapticItem = item
            } else if item.uuid == Pendant.batteryLevel {
                peripheral.setNotifyValue(true, for: item)
                peripheral.readValue(for: item)
            } else if item.uuid == Pendant.firmwareRevision || item.uuid == Pendant.audioCodec {
                peripheral.readValue(for: item)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == Pendant.storageControl, characteristic.isNotifying, !ringAsked {
            ringAsked = true
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.ring.begin() }   // after the live audio started
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        poll()                                   // the read keeps the app awake while it waits for an answer
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == Pendant.haptic {
            if error == nil { hapticConfirmed += 1 } else { hapticFailed += 1 }
        }
        if let error = error { Log.write("write to \(characteristic.uuid.uuidString.prefix(8)) failed: \(error.localizedDescription)") }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else { return }
        if characteristic.uuid == Pendant.audioData {
            audio(value)
        } else if characteristic.uuid == Pendant.storageControl {
            ring.handle(value)
        } else if characteristic.uuid == Pendant.button {
            // 8 bytes; the first number is the event: 1 tap, 2 double tap, 3 long, 4 press, 5 release
            if let event = value.first {
                listenUntil = Date().addingTimeInterval(600)
                // While a question runs, each tap ends it. The pendant can report one tap as a double tap,
                // and a second "start" must never throw away the words that were spoken before it.
                if let start = askStart {
                    if (event == 1 || event == 2), Date().timeIntervalSince(start) > 1.5 { endQuestion() }
                } else if event == 2 {
                    startQuestion()
                }
            }
        } else if characteristic.uuid == Pendant.storageStatus {
            // 16 bytes, four little-endian numbers: used bytes, unread records, free bytes, clock valid
            if value.count >= 16 { ring.clockValid = value[value.startIndex + 12] != 0 }
        } else if characteristic.uuid == Pendant.batteryLevel {
            if let level = value.first { status.set { $0.battery = Int(level) } }
            onAlive?()        // the pendant sends this regularly, also when it is quiet
        } else if characteristic.uuid == Pendant.firmwareRevision {
            let text = String(data: value, encoding: .utf8) ?? ""
            status.set { $0.firmware = text }
        } else if characteristic.uuid == Pendant.audioCodec {
            if let codec = value.first, codec != 21 { Log.write("codec \(codec): this is not the expected Opus format") }
        }
    }

    // MARK: audio

    private func audio(_ value: Data) {
        guard value.count > 3 else { return }
        let now = Date()
        let head = [UInt8](value.prefix(3))
        let number = Int(head[0]) | (Int(head[1]) << 8)
        let part = Int(head[2])
        let body = value.dropFirst(3)

        if now.timeIntervalSince(lastPacketAt) > 1.0 {
            flushFrame()                 // a pause: the earlier frame was complete
            nextStartsRun = true
        } else if let last = lastNumber, ((number - last) & 0xFFFF) != 1 {
            frameValid = false           // packets were lost on the radio link: the frame in work can be damaged
            nextStartsRun = true
        }
        lastNumber = number
        lastPacketAt = now

        if part == 0 {
            flushFrame()
            frame = Data(body)
            frameValid = true
            frameAt = now
            frameStartsRun = nextStartsRun
            nextStartsRun = false
        } else if frameValid {
            frame.append(contentsOf: body)
        }
    }

    private func flushFrame() {
        guard frameValid, !frame.isEmpty else {
            frameValid = false
            return
        }
        writer.append(frame, at: frameAt, newRun: frameStartsRun)
        if askStart != nil { askFrames.append(frame) }
        frameValid = false
        if frameAt.timeIntervalSince(lastShown) > 5 {
            lastShown = frameAt
            let time = frameAt
            status.set { $0.lastAudio = time }
        }
    }

    /// Plays a vibration sign. Each pulse is one write to the pendant, and the pendant confirms each write.
    /// The result goes into the log and to the Mac mini.
    private func play(_ name: String, steps given: [[Int]]? = nil) {
        let steps = given ?? signs[name] ?? Pendant.defaultSigns[name] ?? []
        guard let pendant = peripheral, hapticItem != nil, pendant.state == .connected else {
            Log.write("vibration \(name): no link to the pendant")
            playedReport = "\(name).0.0.0"
            return
        }
        let now = Date()
        var at = max(0, buzzFreeAt.timeIntervalSince(now))          // do not mix two signs
        var pulses = 0
        hapticConfirmed = 0
        hapticFailed = 0
        for step in steps.prefix(12) {
            guard let pulse = step.first, (1...3).contains(pulse) else { continue }
            queue.asyncAfter(deadline: .now() + at) { [weak self] in
                guard let self = self, let pendant = self.peripheral, let item = self.hapticItem else { return }
                pendant.writeValue(Data([UInt8(pulse)]), for: item, type: .withResponse)
            }
            pulses += 1
            let least = [0, 250, 450, 650][pulse]                   // the pulse plus a clear pause
            at += Double(max(step.count > 1 ? step[1] : 0, least)) / 1000
        }
        buzzFreeAt = now.addingTimeInterval(at + 0.4)
        queue.asyncAfter(deadline: .now() + at + 0.8) { [weak self] in
            guard let self = self else { return }
            Log.write("vibration \(name): \(pulses) pulses, \(self.hapticConfirmed) confirmed, \(self.hapticFailed) failed")
            self.playedReport = "\(name).\(pulses).\(self.hapticConfirmed).\(self.hapticFailed)"
        }
    }

    /// While a question waits for its answer, and for 10 minutes after a button event or an app start, the app
    /// asks the Mac mini each 3 seconds: is an answer ready, is there a test vibration, are there other signs?
    private func poll() {
        let now = Date()
        waiting = waiting.filter { now.timeIntervalSince($0.value) < 1500 }
        guard !waiting.isEmpty || now < listenUntil else { return }
        // In a quiet room the pendant sends nothing, and iOS then lets the app sleep. A small read each
        // 2 seconds keeps the app awake, so it can see the answer and can make the pendant vibrate.
        if now.timeIntervalSince(lastWake) >= 2, let pendant = peripheral, pendant.state == .connected {
            lastWake = now
            pendant.readRSSI()
        }
        guard now.timeIntervalSince(lastPoll) >= (pollBusy ? 10 : 3) else { return }
        lastPoll = now
        pollBusy = true
        let report = playedReport
        var query = "clips=" + waiting.keys.sorted().joined(separator: ",") + "&after=\(lastTestID)"
        if let report = report { query += "&played=" + report }
        signal?(query) { [weak self] reply in
            self?.queue.async {
                guard let self = self else { return }
                self.pollBusy = false
                guard let reply = reply else { return }
                if report != nil, self.playedReport == report { self.playedReport = nil }
                self.handle(reply)
            }
        }
    }

    private func handle(_ reply: [String: Any]) {
        var changed = false
        for (name, value) in reply["signs"] as? [String: Any] ?? [:] {
            if let steps = value as? [[Int]], !steps.isEmpty, signs[name] != steps {
                signs[name] = steps
                changed = true
            }
        }
        if changed {
            UserDefaults.standard.set(signs, forKey: "signs")
            Log.write("vibration signs changed")
        }
        var answered = false
        for name in reply["ready"] as? [String] ?? [] where waiting.removeValue(forKey: name) != nil { answered = true }
        if answered {
            Log.write("question: answer is ready")
            play("answer")
        }
        if let test = reply["test"] as? [String: Any], let id = (test["id"] as? NSNumber)?.int64Value, id > lastTestID,
           let steps = test["pattern"] as? [[Int]] {
            lastTestID = id
            play("t\(id)", steps: steps)
        }
    }

    private func startQuestion() {
        askFrames = []
        askStart = Date()
        play("start")
        Log.write("question: start")
    }

    private func endQuestion() {
        guard let start = askStart else { return }
        askStart = nil
        flushFrame()
        let frames = askFrames
        askFrames = []
        guard frames.count > 25 else {                 // less than half a second: ignore
            Log.write("question: too short")
            return
        }
        var body = Data()
        for frame in frames {
            var length = UInt32(frame.count).littleEndian
            body.append(Data(bytes: &length, count: 4))
            body.append(frame)
        }
        let name = String(format: "ask_%@_%.3f.bin", writer.deviceTag, start.timeIntervalSince1970)
        let file = Paths.recording.appendingPathComponent(name)
        do {
            try body.write(to: file)
            Log.write("question: \(frames.count / 50) s")
            play("end")
            waiting[name] = Date()
            onQuestion?(file)
        } catch {
            Log.write("question: cannot write the clip")
        }
    }

    private func idleCheck() {
        let idle = Date().timeIntervalSince(lastPacketAt)
        if idle > 0.5 { flushFrame() }
        if idle > 3 { writer.close() }       // close the file, so that the upload can start
        if let start = askStart, Date().timeIntervalSince(start) > askMaxSeconds { endQuestion() }
        poll()
        ring.tick()
    }
}
