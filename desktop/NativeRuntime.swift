import Foundation
import CoreFoundation
import UserNotifications

final class NativeRuntime {
    static let shared = NativeRuntime()
    let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Agent Display")
    let queue = DispatchQueue(label: "agent-display.engine")
    let worker = DispatchQueue(label: "agent-display.account")
    let rpc = NativeRPC()
    let openCodeServer = OpenCodeServer()
    let openCode = NativeOpenCodeProvider()
    let openCodeWorker = DispatchQueue(label: "agent-display.opencode")
    var openCodeBusy = false, lastOpenCode = 0.0
    var openCodeStatus: JSONObject = ["plan": "OpenCode", "usage": ["lifetimeTokens": 0], "tasks": ["active": 0, "items": [], "headline": "OpenCode starting"]]
    var provider: NativeCodexProvider!
    var bluetooth: NativeBluetooth?
    var server: NativeHTTPServer?
    var timer: DispatchSourceTimer?
    var settings: JSONObject = ["agent": "codex", "bleEnabled": true, "completionHours": 48.0, "pushInterval": 0.25, "accountInterval": 2.0]
    var account: JSONObject = [:], status: JSONObject = [:]
    var device: JSONObject = ["state": "starting", "address": "", "error": ""]
    var token = "", accountBusy = false, started = false
    var lastPush = 0.0, lastAccount = 0.0, sent = 0

    static func validate(_ input: JSONObject, current: JSONObject) throws -> JSONObject {
        var next = current
        for (key, value) in input {
            guard current[key] != nil else { throw NativeError("未知设置：\(key)") }
            next[key] = value
        }
        guard ["codex", "opencode"].contains(string(next["agent"])) else { throw NativeError("Agent 尚未接入") }
        guard let flag = next["bleEnabled"] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { throw NativeError("蓝牙设置必须为布尔值") }
        for (key, range) in [("completionHours", 1.0...168.0), ("pushInterval", 0.1...10.0), ("accountInterval", 2.0...300.0)] {
            guard let value = next[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite, range.contains(value.doubleValue) else { throw NativeError("\(key) 超出允许范围") }
        }
        return next
    }
    func start() {
        guard !started else { return }; started = true
        do {
            settings = try Self.validate(readObject(folder.appendingPathComponent("settings.json")), current: settings)
            let url = folder.appendingPathComponent("control-token")
            token = (try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
            if token.isEmpty {
                token = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data(token.utf8).write(to: url, options: .atomic)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            server = try NativeHTTPServer(port: 8765)
            server?.route = { [weak self] method, path, headers, body, local, reply in
                self?.queue.async { self?.route(method, path, headers, body, local, reply) }
            }
            server?.listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: DispatchQueue.main.async { self?.beginPublishing() }
                case .failed(let error): nativeLog("HTTP startup failed: \(error)"); self?.queue.async { self?.device = ["state": "error", "address": "", "error": error.localizedDescription] }
                default: break
                }
            }
            provider = NativeCodexProvider()
            openCodeWorker.async {
                do { try self.openCodeServer.start(token: self.token) } catch { nativeLog("OpenCode startup: \(error.localizedDescription)") }
            }
            account = readObject(provider.root.appendingPathComponent("codex-tip-status.json"))
            if account.isEmpty { account = ["plan": "Loading…", "quota": [:], "usage": ["lifetimeTokens": 0]] }
            server?.start()
            nativeLog("Native runtime started pid=\(ProcessInfo.processInfo.processIdentifier)")
        } catch { started = false; nativeLog("Startup: \(error.localizedDescription)") }
    }
    private func beginPublishing() {
        bluetooth = NativeBluetooth()
        bluetooth?.onState = { [weak self] state, address, error in self?.queue.async { self?.device = ["state": state, "address": address, "error": error] } }
        bluetooth?.onSent = { [weak self] in self?.queue.async { self?.sent += 1 } }
        bluetooth?.onHide = { [weak self] id in self?.queue.async {
            do {
                if id.hasPrefix("oc:") { try self?.openCode.hide(id) } else { try self?.provider.hide(id) }
                self?.lastPush = 0; self?.lastOpenCode = 0
            } catch { nativeLog("Hide: \(error.localizedDescription)") }
        } }
        bluetooth?.configure(enabled: queue.sync { settings["bleEnabled"] as? Bool ?? true })
        provider.onCompletion = {
            let content = UNMutableNotificationContent(); content.title = "Codex task completed"; content.body = "任务已完成"; content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in if let error { nativeLog("Notifications: \(error.localizedDescription)") } }
        queue.async {
            self.timer = DispatchSource.makeTimerSource(queue: self.queue)
            self.timer?.schedule(deadline: .now(), repeating: .milliseconds(50))
            self.timer?.setEventHandler { [weak self] in self?.tick() }
            self.timer?.resume()
        }
    }
    func stop() {
        queue.sync { timer?.cancel(); timer = nil }
        server?.stop(); bluetooth?.stop(); rpc.shutdown()
        openCodeWorker.sync { openCodeServer.stop() }
        nativeLog("Native runtime stopped")
    }
    private func tick() {
        let now = Date().timeIntervalSince1970
        if now - lastPush >= number(settings["pushInterval"]) {
            lastPush = now
            status = account
            status["tasks"] = provider.taskStatus(retention: number(settings["completionHours"]) * 3600)
            status["updatedAt"] = Int(now)
            let frames = DeviceFrames.all(status, agent: "codex") + DeviceFrames.all(openCodeStatus, agent: "opencode"), enabled = settings["bleEnabled"] as? Bool ?? true
            DispatchQueue.main.async { [weak self] in self?.bluetooth?.configure(enabled: enabled); self?.bluetooth?.send(frames) }
        }
        if !openCodeBusy && now - lastOpenCode >= 1 {
            openCodeBusy = true; lastOpenCode = now
            let retention = number(settings["completionHours"]) * 3600
            openCodeWorker.async {
                _ = self.openCode.taskStatus(retention: retention)
                self.openCode.refreshLive(self.openCodeServer)
                let tasks = self.openCode.taskStatus(retention: retention)
                let value: JSONObject = ["plan": "OpenCode", "agent": "opencode", "tasks": tasks, "quota": [:], "usage": ["lifetimeTokens": 0], "updatedAt": Int(Date().timeIntervalSince1970), "quotaUpdatedAt": Int(Date().timeIntervalSince1970)]
                self.queue.async { self.openCodeStatus = value; self.openCodeBusy = false }
            }
        }
        if !accountBusy && now - lastAccount >= number(settings["accountInterval"]) {
            accountBusy = true; lastAccount = now
            worker.async { self.refreshAccount() }
        }
    }
    private func refreshAccount() {
        do {
            let limits = try rpc.request("account/rateLimits/read"), usage = try rpc.request("account/usage/read")
            let identity = try rpc.request("account/read", ["refreshToken": false])
            let buckets = object(limits["rateLimitsByLimitId"])
            let main = object(buckets["codex"] ?? limits["rateLimits"])
            let other = object(buckets.sorted(by: { $0.key < $1.key }).first(where: { $0.key != "codex" })?.value)
            let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
            let today = (usage["dailyUsageBuckets"] as? [JSONObject])?.first { string($0["startDate"]) == formatter.string(from: Date()) }
            let summary = object(usage["summary"])
            let value: JSONObject = ["plan": string(object(identity["account"])["planType"], "API key"),
                "quota": ["primary": object(main["primary"]), "secondary": object(other["primary"])],
                "resetCredits": number(object(limits["rateLimitResetCredits"])["availableCount"]), "quotaUpdatedAt": Int(Date().timeIntervalSince1970),
                "usage": ["todayTokens": number(today?["tokens"]), "lifetimeTokens": number(summary["lifetimeTokens"]), "peakDailyTokens": number(summary["peakDailyTokens"])]]
            queue.async {
                self.account = value; self.accountBusy = false; self.lastAccount = Date().timeIntervalSince1970
                do { try writeObject(value, to: self.provider.root.appendingPathComponent("codex-tip-status.json")) } catch { nativeLog("Account cache: \(error.localizedDescription)") }
            }
        } catch { queue.async { self.account["error"] = error.localizedDescription; self.accountBusy = false; self.lastAccount = Date().timeIntervalSince1970 } }
    }
    private func route(_ method: String, _ path: String, _ headers: [String: String], _ body: Data, _ local: Bool, _ reply: (Int, JSONObject) -> Void) {
        if method == "GET" && ["/", "/status"].contains(path) { reply(200, status); return }
        if method == "GET" && path == "/status/opencode" { reply(200, openCodeStatus); return }
        guard local && headers["authorization"] == "Bearer " + token else { reply(403, ["error": "Forbidden"]); return }
        if method == "GET" && path == "/api/desktop" {
            let selectedOpenCode = string(settings["agent"]) == "opencode"
            reply(200, ["settings": settings, "device": device, "agents": [["id": provider.id, "name": provider.name, "available": true], ["id": openCode.id, "name": openCode.name, "available": true]], "version": 3, "status": selectedOpenCode ? openCodeStatus : status, "statuses": ["codex": status, "opencode": openCodeStatus], "hiddenCount": selectedOpenCode ? openCode.hiddenCount : provider.hiddenCount,
                        "runtime": ["engine": "native-swift", "pid": ProcessInfo.processInfo.processIdentifier, "sentFrames": sent]])
            return
        }
        guard method == "POST" else { reply(404, ["error": "Not found"]); return }
        do {
            guard let json = try JSONSerialization.jsonObject(with: body) as? JSONObject else { throw NativeError("Expected JSON object") }
            switch path {
            case "/api/settings":
                let next = try Self.validate(json, current: settings)
                try writeObject(next, to: folder.appendingPathComponent("settings.json")); settings = next
            case "/api/tasks/hide":
                let id = string(json["id"])
                if id.hasPrefix("oc:") { try openCode.hide(id) } else { try provider.hide(id) }
                lastOpenCode = 0
            case "/api/tasks/restore":
                if string(settings["agent"]) == "opencode" { try openCode.restoreHidden() } else { try provider.restoreHidden() }
                lastOpenCode = 0
            default: reply(404, ["error": "Not found"]); return
            }
            lastPush = 0; tick(); reply(200, ["ok": true])
        } catch { reply(400, ["error": error.localizedDescription]) }
    }
}
