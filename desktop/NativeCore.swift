import Foundation
import SQLite3

typealias JSONObject = [String: Any]
func object(_ value: Any?) -> JSONObject { value as? JSONObject ?? [:] }
func number(_ value: Any?, _ fallback: Double = 0) -> Double { (value as? NSNumber)?.doubleValue ?? fallback }
func string(_ value: Any?, _ fallback: String = "") -> String { value as? String ?? fallback }
func readObject(_ url: URL) -> JSONObject {
    guard let data = try? Data(contentsOf: url), let json = try? JSONSerialization.jsonObject(with: data) else { return [:] }
    return object(json)
}
func writeObject(_ value: JSONObject, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url, options: .atomic)
}
func match(_ pattern: String, _ source: String, group: Int = 0) -> String? {
    guard let expression = try? NSRegularExpression(pattern: pattern),
          let result = expression.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
          let range = Range(result.range(at: group), in: source) else { return nil }
    return String(source[range])
}
struct NativeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

final class ReadOnlyDatabase {
    private var db: OpaquePointer?
    init(_ url: URL) throws {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if db != nil { sqlite3_close(db); db = nil }
            throw NativeError("Cannot read \(url.lastPathComponent)")
        }
        sqlite3_busy_timeout(db, 50)
    }
    deinit { sqlite3_close(db) }
    func rows(_ sql: String, _ parameters: [String] = []) -> [JSONObject] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in parameters.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
        }
        var result: [JSONObject] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: JSONObject = [:]
            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row[name] = sqlite3_column_int64(statement, column)
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(statement, column)
                case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(statement, column))
                default: break
                }
            }
            result.append(row)
        }
        return result
    }
}

protocol NativeAgentProvider: AnyObject {
    var id: String { get }
    var name: String { get }
    var hiddenCount: Int { get }
    func taskStatus(retention: Double) -> JSONObject
    func hide(_ id: String) throws
    func restoreHidden() throws
}

final class NativeCodexProvider: NativeAgentProvider {
    let id = "codex", name = "Codex"
    let root: URL
    let persist: Bool
    var turns: [String: JSONObject]
    var dismissed: JSONObject
    var files: [String: (offset: UInt64, size: UInt64, mtime: Double)] = [:]
    var fileTurns: [String: String] = [:]
    var pending: [String: String] = [:]
    var asyncCalls: Set<String> = []
    var retrying: [String: String] = [:]
    var logCursor: Int64?
    var ready = false
    var changed = false
    var noticeUntil: Double = 0
    var onCompletion: (() -> Void)?
    var hiddenCount: Int { dismissed.count }

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"), persist: Bool = true) {
        self.root = root; self.persist = persist
        turns = object(readObject(root.appendingPathComponent("codex-tip-task-state.json"))["turns"]).mapValues { object($0) }
        dismissed = readObject(root.appendingPathComponent("codex-tip-dismissed.json"))
        noticeUntil = turns.values.filter { string($0["status"]) == "completed" }.map { number($0["completed_at"]) + 48 * 3600 }.max() ?? 0
    }
    func clearPending(path: String? = nil, turn: String? = nil) {
        for (call, owner) in Array(pending) {
            if owner == turn || (path != nil && string(turns[owner]?["rollout_path"]) == path) {
                pending.removeValue(forKey: call); asyncCalls.remove(call)
            }
        }
    }
    func consume(_ event: JSONObject, path: String, mtime: Double, now: Double = Date().timeIntervalSince1970) {
        let payload = object(event["payload"]), type = string(payload["type"])
        if string(event["type"]) == "response_item" {
            let turn = fileTurns[path] ?? "", call = string(payload["call_id"])
            if type == "message" && string(payload["role"]) == "user" { clearPending(path: path) }
            if ["function_call", "custom_tool_call"].contains(type) && !call.isEmpty && string(turns[turn]?["status"]) == "active" {
                let name = string(payload["name"]).split(separator: ".").last.map(String.init) ?? ""
                let arguments = string(payload["arguments"], string(payload["input"]))
                let input = ["request_user_input", "request_user_input_async"].contains(name)
                let approval = match(#"["']?sandbox_permissions["']?\s*:\s*["']require_escalated["']"#, arguments) != nil
                if input || approval {
                    pending[call] = turn
                    if name == "request_user_input_async" { asyncCalls.insert(call) }
                }
            } else if ["function_call_output", "custom_tool_call_output"].contains(type) {
                let result = string(payload["output"]).data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }
                if !(asyncCalls.contains(call) && object(result)["accepted"] as? Bool == true) {
                    pending.removeValue(forKey: call); asyncCalls.remove(call)
                }
            }
            return
        }
        guard string(event["type"]) == "event_msg" else { return }
        let turn = string(payload["turn_id"])
        guard !turn.isEmpty else { return }
        if type == "task_started" {
            clearPending(path: path)
            fileTurns[path] = turn
            let inferred = match(#"([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})\.jsonl$"#, path, group: 1) ?? ""
            turns[turn] = ["status": "active", "thread_id": string(payload["thread_id"], inferred),
                           "rollout_path": path, "started_at": number(payload["started_at"], now), "last_activity": mtime]
            changed = true
        } else if ["task_complete", "task_failed", "task_interrupted", "turn_aborted"].contains(type) {
            var state = turns[turn] ?? ["thread_id": string(payload["thread_id"]), "started_at": number(payload["started_at"], now)]
            let hasError = payload["error"] != nil && !(payload["error"] is NSNull) && string(payload["error"], "error") != ""
            let next = type == "task_complete" && !hasError ? "completed" : "interrupted"
            if string(state["status"]) != next {
                state["status"] = next; state["completed_at"] = number(payload["completed_at"], now)
                turns[turn] = state; changed = true
                if next == "interrupted" { clearPending(turn: turn) }
                else if ready { noticeUntil = now + 48 * 3600; onCompletion?() }
                turns[turn]?["announced"] = "1"
            }
        }
    }
    func tail(retention: Double) {
        let now = Date().timeIntervalSince1970
        guard let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent("sessions"),
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl", let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
            let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0, size = UInt64(values.fileSize ?? 0)
            guard now - mtime <= max(retention, 172800) else { continue }
            let previous = files[url.path]
            if previous?.size == size && previous?.mtime == mtime && previous?.offset == size { continue }
            var offset = previous?.offset ?? 0
            if size < offset { offset = 0 }
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            do {
                try handle.seek(toOffset: offset)
                // Incomplete trailing records remain unread until their newline arrives.
                var buffer = Data()
                while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    buffer.append(chunk)
                    while let end = buffer.firstIndex(of: 10) {
                        let line = Data(buffer[..<end])
                        let consumed = buffer.distance(from: buffer.startIndex, to: end) + 1
                        offset += UInt64(consumed)
                        buffer.removeFirst(consumed)
                        if let event = try? JSONSerialization.jsonObject(with: line) {
                            consume(object(event), path: url.path, mtime: mtime, now: now)
                        }
                    }
                }
                files[url.path] = (offset, size, mtime)
            } catch { continue }
        }
        ready = true
        if changed && persist {
            do {
                try writeObject(["updatedAt": Int(now), "turns": turns], to: root.appendingPathComponent("codex-tip-task-state.json"))
                changed = false
            } catch { nativeLog("Task cache: \(error.localizedDescription)") }
        }
    }
    func consumeRetry(target: String, thread: String, body: String) {
        guard !thread.isEmpty, let turn = match(#"\bturn_id=([0-9a-f-]{36})"#, body, group: 1) else { return }
        if target == "codex_core::responses_retry" && match(#": (?:stream disconnected - retrying sampling request \(|stream connection failed; waiting to retry\b)"#, body) != nil {
            retrying[thread] = turn
        } else if target == "codex_core::stream_events_utils" && match(#": Output item item_type="[a-z_]+" item_id="[^"\n]+"$"#, body) != nil {
            if retrying[thread] == turn { retrying.removeValue(forKey: thread) }
        }
    }
    func updateRetries() {
        guard let db = try? ReadOnlyDatabase(root.appendingPathComponent("logs_2.sqlite")) else { return }
        let maximum = Int64(number(db.rows("SELECT COALESCE(MAX(id),0) AS maximum FROM logs").first?["maximum"]))
        if logCursor == nil || maximum < logCursor! { logCursor = max(0, maximum - 20000); retrying.removeAll() }
        let rows = db.rows("SELECT id,target,thread_id,feedback_log_body FROM logs WHERE id>? AND id<=? AND target IN ('codex_core::responses_retry','codex_core::stream_events_utils') ORDER BY id LIMIT 2000", [String(logCursor!), String(maximum)])
        for row in rows { consumeRetry(target: string(row["target"]), thread: string(row["thread_id"]), body: string(row["feedback_log_body"])) }
        logCursor = rows.count == 2000 ? Int64(number(rows.last?["id"])) : maximum
    }
    func hidden(_ state: JSONObject) -> Bool {
        guard let cutoff = dismissed[string(state["thread_id"])] else { return false }
        return number(state["started_at"]) <= number(cutoff)
    }
    func taskStatus(retention: Double) -> JSONObject {
        updateRetries(); tail(retention: retention)
        let now = Date().timeIntervalSince1970
        var latest: [String: JSONObject] = [:], completed: [String: JSONObject] = [:]
        for (id, original) in turns {
            var state = original; state["turn_id"] = id
            let thread = string(state["thread_id"], id)
            if number(state["started_at"]) >= number(latest[thread]?["started_at"]) { latest[thread] = state }
            if string(state["status"]) == "completed" && now - number(state["completed_at"]) < retention &&
                number(state["completed_at"]) >= number(completed[thread]?["completed_at"]) { completed[thread] = state }
        }
        let waiting = Set(pending.values)
        var active: [JSONObject] = [], inactive: [JSONObject] = []
        for (thread, var state) in latest {
            let id = string(state["turn_id"]), status = string(state["status"])
            let activity = files[string(state["rollout_path"])]?.mtime ?? number(state["last_activity"], number(state["started_at"]))
            state["waiting"] = waiting.contains(id)
            if waiting.contains(id) || (status == "active" && (retrying[thread] == id || now - activity <= 900)) {
                state["displayStatus"] = waiting.contains(id) ? "WAITING" : retrying[thread] == id ? "RECONNECTING" : "ACTIVE"
                if !hidden(state) { active.append(state) }
                completed.removeValue(forKey: thread)
            } else if status == "interrupted" && now - number(state["completed_at"]) < 1800 {
                state["displayStatus"] = "INTERRUPTED"
                if !hidden(state) { inactive.append(state) }
                completed.removeValue(forKey: thread)
            }
        }
        for var state in completed.values where !hidden(state) { state["displayStatus"] = "COMPLETED"; inactive.append(state) }
        active.sort { number($0["started_at"]) > number($1["started_at"]) }
        inactive.sort { number($0["completed_at"]) > number($1["completed_at"]) }
        let db = try? ReadOnlyDatabase(root.appendingPathComponent("state_5.sqlite"))
        var items: [JSONObject] = [], seen: Set<String> = []
        var activeCount = 0
        for state in active + inactive {
            let thread = string(state["thread_id"])
            let detail = db?.rows("SELECT COALESCE(name,title,preview) AS name,tokens_used,cwd FROM threads WHERE id=?", [thread]).first ?? [:]
            let name = string(detail["name"], "Codex task")
            let identity = name + "\u{0}" + string(detail["cwd"])
            if ["ACTIVE", "WAITING", "RECONNECTING"].contains(string(state["displayStatus"])) {
                if seen.contains(identity) { continue }
                seen.insert(identity); activeCount += 1
            }
            items.append(["id": string(state["turn_id"]), "name": name, "tokens": Int(number(detail["tokens_used"])), "status": string(state["displayStatus"])])
        }
        items = Array(items.prefix(4))
        return ["active": activeCount, "recent": 0, "headline": items.first?["name"] ?? "No active task", "items": items, "event": now < noticeUntil ? "Task completed" : ""]
    }
    func hide(_ id: String) throws {
        guard let state = turns[id], let thread = state["thread_id"] as? String, !thread.isEmpty else { throw NativeError("Task no longer exists") }
        var next = dismissed
        next[thread] = max(number(next[thread]), number(state["started_at"]))
        if persist { try writeObject(next, to: root.appendingPathComponent("codex-tip-dismissed.json")) }
        dismissed = next
    }
    func restoreHidden() throws {
        if persist { try writeObject([:], to: root.appendingPathComponent("codex-tip-dismissed.json")) }
        dismissed.removeAll()
    }
}

enum DeviceFrames {
    static func clean(_ value: Any?, limit: Int = 54) -> String {
        String(string(value).replacingOccurrences(of: ";", with: ",").replacingOccurrences(of: "=", with: ":").replacingOccurrences(of: "\n", with: " ").prefix(limit))
    }
    static func all(_ status: JSONObject, now: Double = Date().timeIntervalSince1970) -> [Data] {
        let quota = object(status["quota"]), usage = object(status["usage"]), tasks = object(status["tasks"])
        let primary = object(quota["primary"]), secondary = object(quota["secondary"])
        let items = Array((tasks["items"] as? [JSONObject] ?? []).prefix(4))
        func n(_ value: Any?, _ fallback: Double = 0) -> String { String(Int(number(value, fallback))) }
        func minutes(_ value: Any?) -> String { value == nil ? "-1" : String(max(0, Int((number(value) - now) / 60))) }
        let fields: [(String, String)] = [
            ("PL", clean(status["plan"], limit: 14)), ("P", n(primary["usedPercent"], -1)), ("S", n(secondary["usedPercent"], -1)),
            ("PR", n(primary["resetsAt"])), ("SR", n(secondary["resetsAt"])), ("C", n(status["resetCredits"])),
            ("PM", minutes(primary["resetsAt"])), ("SM", minutes(secondary["resetsAt"])),
            ("D", n(usage["todayTokens"])), ("L", n(usage["lifetimeTokens"])), ("M", n(usage["peakDailyTokens"])),
            ("A", n(tasks["active"])), ("B", String(items.count)), ("R", n(tasks["recent"])),
            ("Q", now - number(status["quotaUpdatedAt"]) > 90 ? "1" : "0"),
            ("T", clean(tasks["headline"])), ("E", clean(tasks["event"], limit: 42))]
        var frames = [Data(fields.map { "\($0.0)=\($0.1)" }.joined(separator: ";").utf8)]
        for (index, item) in items.enumerated() {
            let state = ["COMPLETED": "DONE", "WAITING": "WAIT", "RECONNECTING": "WAIT", "INTERRUPTED": "STOP"][string(item["status"])] ?? "RUN"
            frames.append(Data("I=\(index);K=\(clean(item["id"]));N=\(clean(item["name"], limit: 18));V=\(n(item["tokens"]));X=\(state)".utf8))
        }
        return frames
    }
}

private let nativeLogLock = NSLock()
func nativeLog(_ text: String) {
    nativeLogLock.lock(); defer { nativeLogLock.unlock() }
    let data = Data((ISO8601DateFormatter().string(from: Date()) + " " + text + "\n").utf8)
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Agent Display.log")
    if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
    if let handle = try? FileHandle(forWritingTo: url) { defer { try? handle.close() }; _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data) }
}
