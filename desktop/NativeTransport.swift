import Foundation
import CoreBluetooth
import Network

final class NativeRPC {
    private let condition = NSCondition()
    private var process: Process?
    private var input: FileHandle?
    private var responses: [Int: JSONObject] = [:]
    private var nextID = 1
    private var generation = UUID()
    private var stopped = false

    func shutdown() {
        condition.lock()
        stopped = true
        let process = self.process
        self.process = nil
        condition.broadcast()
        condition.unlock()
        if process?.isRunning == true { process?.terminate() }
    }
    private func start() throws {
        let process = Process(), stdout = Pipe(), stdin = Pipe()
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates = ["/Applications/Codex.app/Contents/Resources/codex", "/opt/homebrew/bin/codex", home.appendingPathComponent(".local/bin/codex").path]
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        for directory in (try? FileManager.default.contentsOfDirectory(at: nvm, includingPropertiesForKeys: nil)) ?? [] {
            candidates.append(directory.appendingPathComponent("bin/codex").path)
        }
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw NativeError("未找到 Codex，请安装 Codex 应用或 CLI") }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--stdio"]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = URL(fileURLWithPath: executable).deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = environment
        process.standardInput = stdin; process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        condition.lock()
        if stopped { condition.unlock(); throw NativeError("Application stopped") }
        generation = UUID(); let generation = self.generation
        responses.removeAll(); self.process = process; input = stdin.fileHandleForWriting
        condition.unlock()
        try process.run()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var buffer = Data()
            while true {
                let data = stdout.fileHandleForReading.availableData
                if data.isEmpty { break }
                buffer.append(data)
                while let end = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<end]); buffer.removeFirst(buffer.distance(from: buffer.startIndex, to: end) + 1)
                    guard let json = try? JSONSerialization.jsonObject(with: line), let id = object(json)["id"] as? Int else { continue }
                    self?.condition.lock()
                    if self?.generation == generation { self?.responses[id] = object(json) }
                    self?.condition.broadcast(); self?.condition.unlock()
                }
            }
            self?.condition.lock(); self?.condition.broadcast(); self?.condition.unlock()
        }
        _ = try send("initialize", ["clientInfo": ["name": "agent_display", "title": "Agent Display", "version": "2.0.0"], "capabilities": ["experimentalApi": true]])
        try write(["method": "initialized", "params": [:]])
    }
    private func write(_ json: JSONObject) throws {
        var data = try JSONSerialization.data(withJSONObject: json); data.append(10)
        guard let input else { throw NativeError("Codex App Server unavailable") }
        try input.write(contentsOf: data)
    }
    private func send(_ method: String, _ params: JSONObject) throws -> JSONObject {
        let id = nextID; nextID += 1
        try write(["id": id, "method": method, "params": params])
        let deadline = Date().addingTimeInterval(15)
        condition.lock()
        defer { condition.unlock() }
        while responses[id] == nil && !stopped {
            if process?.isRunning != true || !condition.wait(until: deadline) {
                if process?.isRunning == true { process?.terminate() }
                throw NativeError("Codex App Server timeout: \(method)")
            }
        }
        guard let response = responses.removeValue(forKey: id) else { throw NativeError("Codex App Server stopped") }
        if let error = response["error"] { throw NativeError(string(object(error)["message"], "Codex RPC error")) }
        return object(response["result"])
    }
    func request(_ method: String, _ params: JSONObject = [:]) throws -> JSONObject {
        if process?.isRunning != true { try start() }
        return try send(method, params)
    }
}

final class NativeBluetooth: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let service = CBUUID(string: "5f6d0001-7f62-4da0-99e6-401b1de91a00")
    static let statusID = CBUUID(string: "5f6d0002-7f62-4da0-99e6-401b1de91a00")
    static let actionID = CBUUID(string: "5f6d0003-7f62-4da0-99e6-401b1de91a00")
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var characteristic: CBCharacteristic?
    private var queue: [Data] = []
    private var nextFrames: [Data] = []
    private var enabled = true
    private var subscribed = false
    private var connectionStarted = Date()
    var onState: ((String, String, String) -> Void)?
    var onHide: ((String) -> Void)?
    var onSent: (() -> Void)?
    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }
    func configure(enabled: Bool) {
        self.enabled = enabled
        if !enabled {
            central.stopScan(); queue.removeAll(); nextFrames.removeAll()
            if let peripheral { central.cancelPeripheralConnection(peripheral) }
            onState?("paused", "", "")
        } else if central.state == .poweredOn {
            if peripheral == nil { scan() }
            else if characteristic == nil && Date().timeIntervalSince(connectionStarted) > 15, let peripheral {
                central.cancelPeripheralConnection(peripheral)
            }
        }
    }
    func stop() { configure(enabled: false) }
    private func scan() {
        guard enabled && central.state == .poweredOn && peripheral == nil else { return }
        onState?("scanning", "", "")
        central.scanForPeripherals(withServices: [Self.service])
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { scan() }
        else {
            peripheral = nil; characteristic = nil; subscribed = false
            let message = central.state == .unauthorized ? "请在系统设置 → 隐私与安全性 → 蓝牙，允许 Agent Display" : "蓝牙未开启或不可用"
            onState?("error", "", message)
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard enabled && self.peripheral == nil else { return }
        self.peripheral = peripheral; peripheral.delegate = self
        connectionStarted = Date(); central.stopScan()
        onState?("connecting", peripheral.identifier.uuidString, "")
        central.connect(peripheral)
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) { peripheral.discoverServices([Self.service]) }
    func disconnected(_ error: Error?) {
        peripheral = nil; characteristic = nil; subscribed = false; queue.removeAll(); nextFrames.removeAll()
        onState?(enabled ? "scanning" : "paused", "", error?.localizedDescription ?? "")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.scan() }
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) { disconnected(error) }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) { disconnected(error) }
    private func fail(_ error: String) {
        onState?("error", peripheral?.identifier.uuidString ?? "", error)
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { fail(error.localizedDescription); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else { fail("Device service missing"); return }
        peripheral.discoverCharacteristics([Self.statusID, Self.actionID], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { fail(error.localizedDescription); return }
        characteristic = service.characteristics?.first { $0.uuid == Self.statusID }
        guard characteristic != nil else { fail("Device status characteristic missing"); return }
        if let action = service.characteristics?.first(where: { $0.uuid == Self.actionID }) { peripheral.setNotifyValue(true, for: action) }
        onState?("connected", peripheral.identifier.uuidString, "")
        nativeLog("Native BLE connected: \(peripheral.identifier)")
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error { onState?("error", peripheral.identifier.uuidString, error.localizedDescription); return }
        subscribed = characteristic.isNotifying
        nativeLog("Native BLE actions subscribed: \(subscribed)")
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.uuid == Self.actionID, let data = characteristic.value,
              let message = String(data: data, encoding: .utf8), message.hasPrefix("HIDE=") else { return }
        onHide?(String(message.dropFirst(5)))
    }
    func send(_ frames: [Data]) {
        guard enabled, peripheral?.state == .connected, characteristic != nil else { return }
        // Coalesce complete snapshots without growing a backlog on slow links.
        nextFrames = frames
        drain()
    }
    private func drain() {
        guard let peripheral, let characteristic, enabled else { return }
        if queue.isEmpty { queue = nextFrames; nextFrames.removeAll() }
        let limit = peripheral.maximumWriteValueLength(for: .withoutResponse)
        guard queue.allSatisfy({ $0.count <= limit }) else { queue.removeAll(); fail("BLE MTU too small for dashboard frames"); return }
        while !queue.isEmpty && peripheral.canSendWriteWithoutResponse {
            peripheral.writeValue(queue.removeFirst(), for: characteristic, type: .withoutResponse)
            onSent?()
        }
    }
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) { drain() }
}

final class NativeHTTPServer {
    let listener: NWListener
    let queue = DispatchQueue(label: "agent-display.http")
    var route: ((String, String, [String: String], Data, Bool, @escaping (Int, JSONObject) -> Void) -> Void)?
    init(port: UInt16) throws {
        listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    }
    func start() { listener.start(queue: queue) }
    func stop() { listener.cancel() }
    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        let deadline = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline: .now() + 8, execute: deadline)
        var buffer = Data()
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
                if let data { buffer.append(data) }
                guard buffer.count <= 16384 else { connection.cancel(); return }
                if let split = buffer.range(of: Data("\r\n\r\n".utf8)), let header = String(data: buffer[..<split.lowerBound], encoding: .utf8) {
                    let lines = header.components(separatedBy: "\r\n")
                    let first = (lines.first ?? "").split(separator: " ").map(String.init)
                    guard first.count == 3 else { connection.cancel(); return }
                    var headers: [String: String] = [:]
                    for line in lines.dropFirst() {
                        if let colon = line.firstIndex(of: ":") {
                            headers[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                        }
                    }
                    let length = Int(headers["content-length"] ?? "0") ?? -1
                    guard length >= 0 && length <= 4096 && headers["transfer-encoding"] == nil else { connection.cancel(); return }
                    let available = buffer.count - split.upperBound
                    if available >= length {
                        let body = Data(buffer[split.upperBound..<(split.upperBound + length)])
                        var local = false
                        if case .hostPort(let host, _) = connection.endpoint {
                            let address = String(describing: host)
                            local = ["127.0.0.1", "::1", "::ffff:127.0.0.1"].contains(address)
                        }
                        self?.route?(first[0], first[1], headers, body, local) { code, json in
                            let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
                            let reason = code == 200 ? "OK" : "Error"
                            var response = Data("HTTP/1.1 \(code) \(reason)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
                            response.append(data)
                            connection.send(content: response, completion: .contentProcessed { _ in deadline.cancel(); connection.cancel() })
                        }
                        return
                    }
                }
                if complete || error != nil { deadline.cancel(); connection.cancel() } else { receive() }
            }
        }
        receive()
    }
}
