import Foundation

// The server is optional for historical data. Never send prompts or approvals.
final class OpenCodeServer {
    var process: Process?
    var token = ""
    let endpoint = "http://127.0.0.1:4096"
    func get(_ path: String) throws -> Any {
        var request = URLRequest(url: URL(string: endpoint + path)!)
        request.timeoutInterval = 2
        if !token.isEmpty { request.setValue("Basic " + Data(("opencode:" + token).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization") }
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Any, Error> = .failure(NativeError("OpenCode request timed out"))
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error { result = .failure(error); return }
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data else { result = .failure(NativeError("OpenCode HTTP error")); return }
            result = Result { try JSONSerialization.jsonObject(with: data) }
        }
        task.resume()
        semaphore.wait()
        return try result.get()
    }
    func start(token: String) throws {
        self.token = token
        if let health = try? get("/global/health"), object(health)["healthy"] as? Bool == true { return }
        let executable = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".opencode/bin/opencode")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw NativeError("OpenCode CLI 未安装") }
        let child = Process()
        child.executableURL = executable
        child.arguments = ["serve", "--hostname", "127.0.0.1", "--port", "4096"]
        child.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var environment = ProcessInfo.processInfo.environment
        environment["OPENCODE_SERVER_PASSWORD"] = token
        environment["OPENCODE_SERVER_USERNAME"] = "opencode"
        environment["PATH"] = executable.deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        child.environment = environment
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        try child.run(); process = child
        nativeLog("OpenCode server started on loopback:4096 pid=\(child.processIdentifier)")
    }
    func stop() { if process?.isRunning == true { process?.terminate() }; process = nil }
}

final class NativeOpenCodeProvider: NativeAgentProvider {
    let id = "opencode", name = "OpenCode"
    let root: URL, hiddenURL: URL
    let lock = NSLock()
    var dismissed: JSONObject
    var starts: [String: Double] = [:]
    var directories: [String] = []
    var live: JSONObject = [:], waiting: Set<String> = []
    var serviceOnline = false
    var hiddenCount: Int { lock.lock(); defer { lock.unlock() }; return dismissed.count }
    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode"), hiddenURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Agent Display/opencode-hidden.json")) {
        self.root = root; self.hiddenURL = hiddenURL; dismissed = readObject(hiddenURL)
    }
    // Called only on the OpenCode worker, never the BLE/task queue.
    func refreshLive(_ server: OpenCodeServer) {
        var states: JSONObject = [:], pending: Set<String> = []
        serviceOnline = false
        guard let health = try? server.get("/global/health"), object(health)["healthy"] as? Bool == true else { live = [:]; waiting = []; return }
        serviceOnline = true
        for directory in [""] + Array(directories.prefix(8)) {
            let query = directory.isEmpty ? "" : "?directory=" + (directory.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
            if let result = try? server.get("/session/status" + query) { states.merge(object(result)) { _, new in new } }
            for path in ["/permission", "/question"] {
                if let entries = try? server.get(path + query) as? [JSONObject] {
                    for entry in entries { pending.insert(string(entry["sessionID"])) }
                }
            }
        }
        live = states; waiting = pending
    }
    static func displayState(message: JSONObject, live: String, waiting: Bool, now: Double) -> String {
        if waiting { return "WAITING" }
        if live == "retry" { return "RECONNECTING" }
        if live == "busy" { return "ACTIVE" }
        if !object(message["error"]).isEmpty { return "INTERRUPTED" }
        if string(message["role"]) == "assistant" && number(object(message["time"])["completed"]) > 0 && ["stop", "length", "content-filter", "end_turn"].contains(string(message["finish"])) { return "COMPLETED" }
        // A standalone TUI has its own in-memory status. Its database only proves
        // recent activity, not whether a permission prompt is currently visible.
        if now - number(object(message["time"])["created"]) / 1000 < 60 { return "ACTIVE" }
        return "UNKNOWN"
    }
    func taskStatus(retention: Double) -> JSONObject {
        lock.lock(); defer { lock.unlock() }
        guard let db = try? ReadOnlyDatabase(root.appendingPathComponent("opencode.db")) else {
            return ["active": 0, "recent": 0, "headline": "No OpenCode data", "items": [], "event": "Database unavailable"]
        }
        let now = Date().timeIntervalSince1970
        let sessions = db.rows("SELECT id,title,directory,time_updated,tokens_input,tokens_output,tokens_reasoning,tokens_cache_read,tokens_cache_write FROM session WHERE time_archived IS NULL AND parent_id IS NULL AND time_updated>? ORDER BY time_updated DESC LIMIT 100", [String(Int((now - max(retention, 1800)) * 1000))])
        directories = Array(Set(sessions.map { string($0["directory"]) }.filter { !$0.isEmpty })).sorted()
        var items: [JSONObject] = []
        starts.removeAll()
        for session in sessions {
            let sessionID = string(session["id"]), displayID = "oc:" + sessionID
            let messages = db.rows("SELECT data FROM message WHERE session_id=? ORDER BY time_created DESC,id DESC LIMIT 1", [sessionID])
            guard let data = string(messages.first?["data"]).data(using: .utf8), let decoded = try? JSONSerialization.jsonObject(with: data) else { continue }
            let message = object(decoded)
            let user = db.rows("SELECT time_created FROM message WHERE session_id=? AND json_extract(data,'$.role')='user' ORDER BY time_created DESC LIMIT 1", [sessionID]).first
            let start = number(user?["time_created"], number(session["time_updated"]))
            starts[displayID] = start
            if let cutoff = dismissed[displayID], start <= number(cutoff) { continue }
            let state = Self.displayState(message: message, live: string(object(live[sessionID])["type"]), waiting: waiting.contains(sessionID), now: now)
            let activity = max(number(object(message["time"])["completed"]), number(object(message["time"])["created"])) / 1000
            if state == "COMPLETED" && now - activity >= retention { continue }
            if ["INTERRUPTED", "UNKNOWN"].contains(state) && now - activity >= 1800 { continue }
            let tokens = ["tokens_input", "tokens_output", "tokens_reasoning", "tokens_cache_read", "tokens_cache_write"].reduce(0.0) { $0 + number(session[$1]) }
            items.append(["id": displayID, "name": string(session["title"], "OpenCode task"), "status": state, "tokens": Int(tokens), "activity": activity])
        }
        func active(_ item: JSONObject) -> Bool { ["ACTIVE", "WAITING", "RECONNECTING"].contains(string(item["status"])) }
        items.sort { active($0) != active($1) ? active($0) : number($0["activity"]) > number($1["activity"]) }
        let activeCount = items.filter(active).count
        items = Array(items.prefix(4))
        return ["active": activeCount, "recent": 0, "headline": items.first?["name"] ?? "No OpenCode tasks", "items": items, "event": serviceOnline ? "OpenCode online" : "OpenCode offline"]
    }
    func hide(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard let start = starts[id] else { throw NativeError("OpenCode task no longer exists") }
        var next = dismissed; next[id] = start
        try writeObject(next, to: hiddenURL); dismissed = next
    }
    func restoreHidden() throws {
        lock.lock(); defer { lock.unlock() }
        try writeObject([:], to: hiddenURL); dismissed = [:]
    }
}
