import CoreBluetooth
import Foundation

public struct LampState: Codable, Equatable {
    public var power: Bool
    public var lumens: Int
    /// Linear position in the 100–1000 lm range. The lamp has its own, different percentage.
    public var brightness: Int
    public var kelvin: Int
    public var autoBrightness: Bool
    public var movement: Bool
    /// nil when the lamp did not answer on the attribute channel.
    public var daylight: Bool?
    public var preset: Preset?
}

public struct DiscoveredLamp: Codable {
    public let id: UUID
    public let name: String
    public let rssi: Int
    public let services: [String]
}

/// One BLE session with the lamp: find, connect, handshake, read, write.
///
/// All CoreBluetooth state lives on `queue`. The async methods register a
/// waiter on that queue and the delegate callbacks resolve it.
public final class Lamp: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    public var log: (String) -> Void = { _ in }
    /// Called on the Bluetooth queue when a notification changed the live state.
    public var onStateChange: ((LampState) -> Void)?
    /// Called on the Bluetooth queue when the connection ends for any reason.
    public var onDisconnect: (() -> Void)?

    private let queue = DispatchQueue(label: "solarmorph.ble")
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var chars: [CBUUID: CBCharacteristic] = [:]
    private var assembler = MessageAssembler()
    private var pendingServices = 0
    private var lastControlWrite = Date.distantPast

    private struct Pending {
        let id: Int
        let resolve: (Any) -> Void
        let reject: (Error) -> Void
    }

    private var pending: [String: Pending] = [:]
    /// Replies that arrived before their waiter registered.
    private var mailbox: [String: Any] = [:]
    private var nextPendingId = 0

    private var authenticated = false
    /// The live state. nil until `enableLiveState`, and nil again after a disconnect.
    private var cache: LampState?
    private var scanTarget: String?
    private var scanResults: [UUID: DiscoveredLamp]?

    // MARK: - Public API

    public func powerOn() async throws {
        let _: Bool = try await wait("state", timeout: 10) {
            self.central = CBCentralManager(delegate: self, queue: self.queue)
        }
    }

    /// True between a complete handshake and the end of the connection. The
    /// daemon uses it to see that the lamp dropped an idle connection.
    public var isReady: Bool {
        get async { (try? await onQueue { self.authenticated }) ?? false }
    }

    /// List the nearby peripherals that have a name, strongest signal first.
    public func scan(seconds: TimeInterval) async throws -> [DiscoveredLamp] {
        let found: [DiscoveredLamp] = try await wait("scan", timeout: seconds + 2) {
            self.scanResults = [:]
            self.central.scanForPeripherals(withServices: nil)
            self.queue.asyncAfter(deadline: .now() + seconds) {
                self.central.stopScan()
                let results = self.scanResults ?? [:]
                self.scanResults = nil
                self.resolve("scan", Array(results.values))
            }
        }
        return found.sorted { $0.rssi > $1.rssi }
    }

    /// Connect and do the handshake.
    ///
    /// - Returns: the CoreBluetooth identifier of the lamp, to pass as `cachedId` next time.
    public func connect(serial: String, accountId: String, ltkHex: String, cachedId: UUID?) async throws -> UUID {
        let hexDigits = ltkHex.filter(\.isHexDigit)
        guard let ltk = Data(hex: hexDigits), !ltk.isEmpty else {
            throw MorphError.protocolError("The stored key is not hexadecimal.")
        }
        let key = MorphCrypto.deriveAesKey(ltk: ltk)

        // macOS remembers a peripheral by identifier, which saves the scan.
        if let cachedId, let known = try await onQueue({ self.central.retrievePeripherals(withIdentifiers: [cachedId]).first }) {
            log("Trying the remembered peripheral \(cachedId)")
            if try await connectAndAuthenticate(known, attempts: 2, accountId: accountId, key: key) {
                return known.identifier
            }
        }

        log("Scanning for \(serial)")
        let found: CBPeripheral
        do {
            found = try await wait("find", timeout: 15) {
                self.scanTarget = serial.uppercased()
                self.central.scanForPeripherals(withServices: nil)
            }
        } catch {
            // Stop the scan, so that it does not continue in the daemon.
            try? await onQueue {
                self.central.stopScan()
                self.scanTarget = nil
            }
            guard case MorphError.timeout = error else { throw error }
            throw MorphError.bluetooth(
                "Could not find \(serial) nearby. Make sure that the lamp has power and that no other device holds the connection.")
        }
        if try await connectAndAuthenticate(found, attempts: 3, accountId: accountId, key: key) {
            return found.identifier
        }
        throw MorphError.bluetooth(
            "Could not connect to \(serial). Make sure that no other device holds the connection "
                + "(MyDyson app, Homebridge). If the lamp refuses all connections, remove its power for ten seconds."
        )
    }

    /// Subscribe to the state characteristics and keep a copy of the state current.
    ///
    /// The attribute channel already reports daylight mode and the presets. From
    /// here on, `state(fresh: false)` needs no round trip to the lamp.
    public func enableLiveState(seed: LampState? = nil) async throws {
        let initial: LampState
        if let seed { initial = seed } else { initial = try await readState(attributes: true) }
        // The copy exists before the subscription, so that no notification is lost.
        try await onQueue {
            guard self.authenticated else { return }
            self.cache = initial
        }
        do {
            for uuid in LampState.liveCharacteristics {
                let _: Bool = try await wait("notify:\(uuid)", timeout: 5) {
                    self.peripheral?.setNotifyValue(true, for: try self.characteristic(uuid))
                }
            }
            // A value that changed before the subscription has no notification, for
            // example the end of a ramp. Read again: each read goes into the copy.
            _ = try await readState(attributes: false)
        } catch {
            try? await onQueue { self.cache = nil }
            throw error
        }
        log("The live state is on")
    }

    public var isLive: Bool {
        get async { (try? await onQueue { self.cache != nil }) ?? false }
    }

    /// The state after a command.
    ///
    /// - Parameter fresh: read the lamp and not the live copy. Necessary after a
    ///   write of a value that the lamp ramps to, and for an explicit refresh.
    public func state(attributes: Bool, fresh: Bool) async throws -> LampState {
        guard await isLive else { return try await readState(attributes: attributes) }
        if fresh {
            // Each read also goes into the live copy, which keeps the attributes that this read skips.
            _ = try await readState(attributes: attributes)
        }
        guard let cached = try await onQueue({ self.cache }) else {
            throw MorphError.bluetooth("The lamp disconnected.")
        }
        return cached
    }

    /// - Parameter attributes: also ask for daylight mode and the preset. Each
    ///   question is a paced round trip, so a caller that only switches the lamp omits them.
    public func readState(attributes: Bool = true) async throws -> LampState {
        let power = try await readByte(CharUUID.power) != 0
        let lumens = try await readWord(CharUUID.brightnessLm)
        let kelvin = try await readWord(CharUUID.colorTemp)
        let auto = try await readByte(CharUUID.autoBrightness) != 0
        let movement = try await readByte(CharUUID.movement) != 0

        var state = LampState(
            power: power, lumens: lumens, brightness: lumensToPercent(lumens), kelvin: kelvin,
            autoBrightness: auto, movement: movement, daylight: nil, preset: nil
        )
        // Best effort. A lamp that does not answer leaves these as nil.
        if attributes, let daylight = try? await readAttribute(Attribute.daylight) {
            state.daylight = daylight.first.map { $0 != 0 }
            for preset in Preset.allCases {
                if let value = try? await readAttribute(preset.attribute), value.first ?? 0 != 0 {
                    state.preset = preset
                }
            }
        }
        return state
    }

    /// Power is the only control with an unambiguous result, so check it and try one more time.
    public func setPower(_ on: Bool) async throws {
        for attempt in 1...2 {
            try await writeControl(Data([on ? 1 : 0]), to: CharUUID.power)
            try await Task.sleep(nanoseconds: 250_000_000)
            let isOn = try await readByte(CharUUID.power) != 0
            if isOn == on { return }
            log("Power write \(attempt) did not take effect")
        }
        throw MorphError.bluetooth("The lamp did not change its power state.")
    }

    public func togglePower() async throws {
        try await setPower(try await readByte(CharUUID.power) == 0)
    }

    public func setLumens(_ lumens: Int) async throws {
        let clamped = min(Limits.lumens.upperBound, max(Limits.lumens.lowerBound, lumens))
        try await writeControl(le16(UInt16(clamped)), to: CharUUID.brightnessLm)
    }

    public func setKelvin(_ kelvin: Int) async throws {
        let clamped = min(Limits.kelvin.upperBound, max(Limits.kelvin.lowerBound, kelvin))
        try await writeControl(le16(UInt16(clamped)), to: CharUUID.colorTemp)
    }

    public func setAutoBrightness(_ on: Bool) async throws {
        try await writeControl(Data([on ? 1 : 0]), to: CharUUID.autoBrightness)
    }

    public func setMovement(_ on: Bool) async throws {
        try await writeControl(Data([on ? 1 : 0]), to: CharUUID.movement)
    }

    public func setDaylight(_ on: Bool) async throws {
        try await writeAttribute(Attribute.daylight, value: Data([on ? 1 : 0]))
    }

    /// Activate a preset. `nil` clears the active preset.
    public func setPreset(_ preset: Preset?) async throws {
        if let preset {
            try await writeAttribute(preset.attribute, value: Data([1]))
            return
        }
        for candidate in Preset.allCases {
            if let value = try? await readAttribute(candidate.attribute), value.first ?? 0 != 0 {
                try await writeAttribute(candidate.attribute, value: Data([0]))
            }
        }
    }

    public func disconnect() async {
        guard let peripheral, peripheral.state != .disconnected else { return }
        let _: Bool? = try? await wait("disconnect", timeout: 3) {
            self.central.cancelPeripheralConnection(peripheral)
        }
    }

    // MARK: - Connect and handshake

    private func connectAndAuthenticate(_ target: CBPeripheral, attempts: Int, accountId: String, key: Data) async throws -> Bool {
        var silent = 0
        for attempt in 1...attempts {
            do {
                let _: Bool = try await wait("connect", timeout: 8) {
                    self.peripheral = target
                    target.delegate = self
                    self.central.connect(target)
                }
                log("Connected")
                try await discover(target)
                log("Discovered the characteristics")
                try await authenticate(accountId: accountId, key: key)
                return true
            } catch let error as MorphError {
                // A wrong key does not get better with another attempt.
                if case .protocolError = error { throw error }
                if case .timeout(let key) = error, key.hasPrefix("msg:") { silent += 1 }
                log("Attempt \(attempt) failed: \(error)")
            } catch {
                log("Attempt \(attempt) failed: \(error.localizedDescription)")
            }
            try? await onQueue { self.central.cancelPeripheralConnection(target) }
            try await Task.sleep(nanoseconds: UInt64(attempt) * 700_000_000)
        }
        // The link is good but the lamp does not talk. A scan cannot help, so stop here.
        // This is what a second program sees while a first one has the session.
        if silent == attempts {
            throw MorphError.bluetooth(
                "The lamp accepted the connection but did not answer the handshake. A different program or device "
                    + "probably has the session (the MyDyson app, Homebridge, or a second morph process).")
        }
        return false
    }

    private func discover(_ target: CBPeripheral) async throws {
        // Characteristics are spread over three services, so sweep all of them.
        let _: Bool = try await wait("discover", timeout: 15) {
            self.chars = [:]
            target.discoverServices(nil)
        }
        let _: Bool = try await wait("notify:\(CharUUID.auth)", timeout: 5) {
            target.setNotifyValue(true, for: try self.characteristic(CharUUID.auth))
        }
    }

    /// LTK re-authentication. The lamp discards all control writes until
    /// it answers with `connectionEstablished`.
    private func authenticate(accountId: String, key: Data) async throws {
        try await onQueue { self.assembler = MessageAssembler() }

        // Some firmware needs the product-info exchange before it talks auth.
        try await send(MsgType.requestProductInfo)
        if (try? await message(MsgType.productInfo, timeout: 2)) == nil {
            log("No product info returned; continuing with the handshake")
        }

        try await send(MsgType.reauthPayloadA, payload: MorphCrypto.buildReauthPayloadA(accountId: accountId, key: key))
        let payloadB = try await message(MsgType.reauthPayloadB, timeout: 6)

        let challenge = try MorphCrypto.parseReauthPayloadB(key: key, payload: payloadB)
        try await send(MsgType.reauthPayloadC, payload: MorphCrypto.buildReauthPayloadC(key: key, challenge: challenge))
        _ = try await message(MsgType.connectionEstablished, timeout: 6)
        try await onQueue { self.authenticated = true }
        log("Handshake complete")

        // The attribute channel refuses the subscription before the handshake.
        if let attribute = try await onQueue({ self.chars[CBUUID(string: CharUUID.attribute)] }) {
            let _: Bool? = try? await wait("notify:\(CharUUID.attribute)", timeout: 5) {
                self.peripheral?.setNotifyValue(true, for: attribute)
            }
        }
    }

    private func send(_ type: UInt8, payload: Data = Data()) async throws {
        try await onQueue { self.mailbox = self.mailbox.filter { !$0.key.hasPrefix("msg:") } }
        for fragment in fragmentMessage(type: type, payload: payload) {
            try await write(fragment, to: CharUUID.auth)
        }
    }

    private func message(_ type: UInt8, timeout: TimeInterval) async throws -> Data {
        try await wait("msg:\(type)", timeout: timeout) {}
    }

    // MARK: - Reads and writes

    private func readByte(_ uuid: String) async throws -> UInt8 {
        guard let byte = try await read(uuid).first else {
            throw MorphError.protocolError("Empty value from \(uuid)")
        }
        return byte
    }

    private func readWord(_ uuid: String) async throws -> Int {
        guard let word = readLE16(try await read(uuid)) else {
            throw MorphError.protocolError("Short value from \(uuid)")
        }
        return word
    }

    private func read(_ uuid: String) async throws -> Data {
        try await wait("read:\(uuid)", timeout: 5) {
            self.peripheral?.readValue(for: try self.characteristic(uuid))
        }
    }

    private func readAttribute(_ attribute: UInt16) async throws -> Data {
        let key = "attr:\(attribute)"
        try await onQueue { self.mailbox.removeValue(forKey: key) }
        for fragment in buildAttributeRead(attribute) {
            try await writeControl(fragment, to: CharUUID.attribute)
        }
        return try await wait(key, timeout: 2) {}
    }

    private func writeAttribute(_ attribute: UInt16, value: Data) async throws {
        let key = "ack:\(attribute)"
        try await onQueue { self.mailbox.removeValue(forKey: key) }
        for fragment in buildAttributeWrite(attribute, value: value) {
            try await writeControl(fragment, to: CharUUID.attribute)
        }
        let status: UInt8 = try await wait(key, timeout: 3) {}
        guard status == 0 else {
            throw MorphError.protocolError("The lamp refused attribute 0x\(String(attribute, radix: 16)) with status \(status).")
        }
        // The acknowledgement is certain. A report of the change is possibly not, so do not wait for one.
        try await onQueue { self.updateLive { $0.apply(attribute: attribute, value: value) } }
    }

    /// A control write, kept `minWriteGap` behind the previous one.
    private func writeControl(_ data: Data, to uuid: String) async throws {
        let delay = try await onQueue { Limits.minWriteGap - Date().timeIntervalSince(self.lastControlWrite) }
        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        try await write(data, to: uuid)
        try await onQueue { self.lastControlWrite = Date() }
    }

    private func write(_ data: Data, to uuid: String) async throws {
        // Use the write mode that the characteristic declares. This lamp
        // declares only write-without-response, but other models can differ.
        let acknowledged = try await onQueue { try self.characteristic(uuid).properties.contains(.write) }
        if acknowledged {
            let _: Bool = try await wait("write:\(uuid)", timeout: 5) {
                self.peripheral?.writeValue(data, for: try self.characteristic(uuid), type: .withResponse)
            }
            return
        }
        let _: Bool = try await wait("ready", timeout: 3) {
            if self.peripheral?.canSendWriteWithoutResponse == true { self.resolve("ready", true) }
        }
        try await onQueue {
            self.peripheral?.writeValue(data, for: try self.characteristic(uuid), type: .withoutResponse)
        }
    }

    private func characteristic(_ uuid: String) throws -> CBCharacteristic {
        guard let c = chars[CBUUID(string: uuid)] else {
            throw MorphError.bluetooth("The lamp does not have characteristic \(uuid).")
        }
        return c
    }

    // MARK: - Waiters

    @discardableResult
    private func onQueue<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }

    private func wait<T>(_ key: String, timeout: TimeInterval, _ start: @escaping () throws -> Void) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            queue.async {
                // One waiter for each key. A replaced waiter must not wait forever.
                self.fail(key, MorphError.protocolError("A second wait for \(key) replaced this one."))
                self.nextPendingId += 1
                let id = self.nextPendingId
                self.pending[key] = Pending(
                    id: id,
                    resolve: { value in
                        if let typed = value as? T {
                            continuation.resume(returning: typed)
                        } else {
                            continuation.resume(throwing: MorphError.protocolError("Unexpected value for \(key)"))
                        }
                    },
                    reject: { continuation.resume(throwing: $0) }
                )
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    if self.pending[key]?.id == id { self.fail(key, MorphError.timeout(key)) }
                }
                if let early = self.mailbox.removeValue(forKey: key) {
                    self.resolve(key, early)
                    return
                }
                do { try start() } catch { self.fail(key, error) }
            }
        }
    }

    private func resolve(_ key: String, _ value: Any) {
        pending.removeValue(forKey: key)?.resolve(value)
    }

    /// Resolve the waiter, or keep the value for a waiter that registers later.
    private func deliver(_ key: String, _ value: Any) {
        if pending[key] != nil { resolve(key, value) } else { mailbox[key] = value }
    }

    private func fail(_ key: String, _ error: Error) {
        pending.removeValue(forKey: key)?.reject(error)
    }

    // MARK: - CBCentralManagerDelegate

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            resolve("state", true)
        case .unauthorized:
            fail("state", MorphError.bluetooth(
                "Bluetooth permission denied. Allow the app that runs morph in System Settings > Privacy & Security > Bluetooth."))
        case .poweredOff:
            fail("state", MorphError.bluetooth("Bluetooth is off."))
        case .unsupported:
            fail("state", MorphError.bluetooth("This Mac does not support Bluetooth LE."))
        default:
            break
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard let name = advertised ?? peripheral.name else { return }

        if scanResults != nil {
            let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []).map(\.uuidString)
            scanResults?[peripheral.identifier] = DiscoveredLamp(
                id: peripheral.identifier, name: name, rssi: RSSI.intValue, services: services)
        }
        // The lamp advertises its serial number as its name.
        if let target = scanTarget, name.uppercased() == target {
            scanTarget = nil
            central.stopScan()
            resolve("find", peripheral)
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        resolve("connect", true)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        fail("connect", MorphError.bluetooth("Connection failed: \(error?.localizedDescription ?? "unknown error")"))
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        authenticated = false
        cache = nil
        onDisconnect?()
        let waiters = pending
        pending = [:]
        for (key, waiter) in waiters {
            if key == "disconnect" {
                waiter.resolve(true)
            } else {
                waiter.reject(MorphError.bluetooth("The lamp disconnected: \(error?.localizedDescription ?? "no reason given")"))
            }
        }
    }

    // MARK: - CBPeripheralDelegate

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        guard error == nil, !services.isEmpty else {
            fail("discover", MorphError.bluetooth("Service discovery failed: \(error?.localizedDescription ?? "no services")"))
            return
        }
        pendingServices = services.count
        services.forEach { peripheral.discoverCharacteristics(nil, for: $0) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            chars[c.uuid] = c
        }
        pendingServices -= 1
        if pendingServices == 0 { resolve("discover", true) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let key = "notify:\(characteristic.uuid.uuidString)"
        if let error {
            fail(key, MorphError.bluetooth("Subscription failed: \(error.localizedDescription)"))
        } else {
            resolve(key, true)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let key = "write:\(characteristic.uuid.uuidString)"
        if let error {
            fail(key, MorphError.bluetooth("Write failed: \(error.localizedDescription)"))
        } else {
            resolve(key, true)
        }
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        resolve("ready", true)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = characteristic.uuid.uuidString
        if let error {
            fail("read:\(uuid)", MorphError.bluetooth("Read failed: \(error.localizedDescription)"))
            return
        }
        guard let data = characteristic.value else { return }

        switch uuid {
        case CharUUID.auth:
            if let message = assembler.push(data) {
                log("← message 0x\(String(message.type, radix: 16)) (\(message.payload.count) bytes)")
                deliver("msg:\(message.type)", message.payload)
            }
        case CharUUID.attribute:
            switch decodeAttributeNotification(data) {
            case .value(let attribute, let value):
                if let value { updateLive { $0.apply(attribute: attribute, value: value) } }
                deliver("attr:\(attribute)", value ?? Data())
            case .ack(let attribute, let status):
                deliver("ack:\(attribute)", status)
            case .report(let attribute, let value):
                log("← attribute 0x\(String(attribute, radix: 16)) changed to \(value.hex)")
                updateLive { $0.apply(attribute: attribute, value: value) }
            case nil:
                log("← attribute channel: \(data.hex)")
            }
        default:
            // A read reply and a notification arrive here in the same way.
            updateLive { $0.apply(characteristic: uuid, value: data) }
            resolve("read:\(uuid)", data)
        }
    }

    private func updateLive(_ change: (inout LampState) -> Bool) {
        guard var state = cache, change(&state) else { return }
        cache = state
        onStateChange?(state)
    }
}
