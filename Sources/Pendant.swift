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
        queue.sync { SegmentWriter.recoverLeftovers() }
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

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error { Log.write("write to \(characteristic.uuid.uuidString.prefix(8)) failed: \(error.localizedDescription)") }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else { return }
        if characteristic.uuid == Pendant.audioData {
            audio(value)
        } else if characteristic.uuid == Pendant.storageControl {
            ring.handle(value)
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
        frameValid = false
        if frameAt.timeIntervalSince(lastShown) > 5 {
            lastShown = frameAt
            let time = frameAt
            status.set { $0.lastAudio = time }
        }
    }

    private func idleCheck() {
        let idle = Date().timeIntervalSince(lastPacketAt)
        if idle > 0.5 { flushFrame() }
        if idle > 3 { writer.close() }       // close the file, so that the upload can start
        ring.tick()
    }
}
