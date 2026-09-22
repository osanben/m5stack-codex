import Foundation

enum NativeTests {
    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-display-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = NativeCodexProvider(root: root, persist: false)
        let now = Date().timeIntervalSince1970
        let thread = "11111111-1111-1111-1111-111111111111", turn = "22222222-2222-2222-2222-222222222222"
        let path = root.appendingPathComponent("sessions/rollout-" + thread + ".jsonl").path
        func event(_ type: String, _ payload: JSONObject) { provider.consume(["type": type, "payload": payload], path: path, mtime: now, now: now) }
        func check(_ value: Bool, _ message: String) throws { if !value { throw NativeError("FAIL: " + message) }; print("PASS: " + message) }
        event("event_msg", ["type": "task_started", "turn_id": turn, "started_at": now])
        event("response_item", ["type": "function_call", "name": "functions.request_user_input_async", "call_id": "ask", "arguments": "{}"])
        event("response_item", ["type": "function_call_output", "call_id": "ask", "output": "{\"accepted\":true}"])
        event("event_msg", ["type": "task_complete", "turn_id": turn, "completed_at": now])
        func status() -> String { string((provider.taskStatus(retention: 72 * 3600)["items"] as? [JSONObject])?.first?["status"]) }
        try check(status() == "WAITING", "异步确认跨任务结束保持红色")
        event("response_item", ["type": "message", "role": "user"])
        try check(status() == "COMPLETED", "用户回复清除等待确认")
        try provider.hide(turn)
        try check((provider.taskStatus(retention: 72 * 3600)["items"] as? [JSONObject])?.isEmpty == true, "隐藏任务")
        event("event_msg", ["type": "task_started", "turn_id": "new", "started_at": now + 1])
        try check(status() == "ACTIVE", "同一任务新一轮重新出现")
        event("event_msg", ["type": "turn_aborted", "turn_id": "new", "completed_at": now])
        try check(status() == "INTERRUPTED", "Esc 显示中断")
        try provider.restoreHidden()
        provider.turns.removeValue(forKey: "new")
        provider.turns[turn]?["completed_at"] = now - 71 * 3600
        try check(status() == "COMPLETED", "完成任务保留 72 小时")
        provider.turns[turn]?["completed_at"] = now - 73 * 3600
        try check(status().isEmpty, "72 小时后过期")
        provider.consumeRetry(target: "codex_core::responses_retry", thread: thread, body: "turn_id=\(turn): stream connection failed; waiting to retry")
        try check(provider.retrying[thread] == turn, "网络等待日志识别")
        let frames = DeviceFrames.all(["tasks": ["items": [["id": turn, "name": "测试任务", "status": "RECONNECTING", "tokens": 123]]]])
        try check(String(decoding: frames[1], as: UTF8.self).contains("X=WAIT"), "重连编码为红色 WAIT")
        let defaults: JSONObject = ["agent": "codex", "bleEnabled": true, "completionHours": 72.0, "pushInterval": 0.25, "accountInterval": 2.0]
        for invalid: JSONObject in [["accountInterval": 1], ["bleEnabled": 1], ["completionHours": 169], ["agent": "opencode"]] {
            var rejected = false
            do { _ = try NativeRuntime.validate(invalid, current: defaults) } catch { rejected = true }
            try check(rejected, "拒绝无效设置 \(invalid.keys.first!)")
        }
        let partialURL = URL(fileURLWithPath: path)
        let record = try JSONSerialization.data(withJSONObject: ["type": "event_msg", "payload": ["type": "task_started", "turn_id": "partial", "started_at": now + 2]])
        try record.write(to: partialURL)
        provider.tail(retention: 72 * 3600)
        try check(provider.turns["partial"] == nil, "不消费未完成的日志行")
        var complete = record; complete.append(10); try complete.write(to: partialURL)
        provider.tail(retention: 72 * 3600)
        try check(provider.turns["partial"] != nil, "日志行完成后立即消费")
        let persistent = NativeCodexProvider(root: root)
        _ = persistent.taskStatus(retention: 72 * 3600)
        try persistent.hide("partial")
        let reloaded = NativeCodexProvider(root: root)
        try check(reloaded.hiddenCount == 1 && reloaded.hidden(reloaded.turns["partial"] ?? [:]), "隐藏记录与任务缓存跨重启保留")
        try reloaded.restoreHidden()
        try check(NativeCodexProvider(root: root).hiddenCount == 0, "恢复隐藏记录持久化")
        print("All native tests passed")
    }
}
