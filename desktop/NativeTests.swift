import Foundation
import SQLite3

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
        func status() -> String { string((provider.taskStatus(retention: 48 * 3600)["items"] as? [JSONObject])?.first?["status"]) }
        try check(status() == "WAITING", "异步确认跨任务结束保持红色")
        event("response_item", ["type": "message", "role": "user"])
        try check(status() == "COMPLETED", "用户回复清除等待确认")
        try provider.hide(turn)
        try check((provider.taskStatus(retention: 48 * 3600)["items"] as? [JSONObject])?.isEmpty == true, "隐藏任务")
        event("event_msg", ["type": "task_started", "turn_id": "new", "started_at": now + 1])
        try check(status() == "ACTIVE", "同一任务新一轮重新出现")
        event("event_msg", ["type": "turn_aborted", "turn_id": "new", "completed_at": now])
        try check(status() == "INTERRUPTED", "Esc 显示中断")
        try provider.restoreHidden()
        provider.turns.removeValue(forKey: "new")
        provider.turns[turn]?["completed_at"] = now - 47 * 3600
        try check(status() == "COMPLETED", "完成 47 小时仍保留")
        provider.turns[turn]?["completed_at"] = now - 48 * 3600
        try check(status().isEmpty, "48 小时后过期")
        try check(TaskItem(id: "test", name: "test", tokens: 0, status: "ACTIVE").color == .green, "运行中为绿色")
        try check(TaskItem(id: "test", name: "test", tokens: 0, status: "COMPLETED").color == .yellow, "已完成为黄色")
        try check(TaskItem(id: "test", name: "test", tokens: 0, status: "WAITING").color == .red, "待确认仍为红色")
        try check(TaskItem(id: "test", name: "test", tokens: 0, status: "RECONNECTING").color == .red, "重连仍为红色")
        provider.consumeRetry(target: "codex_core::responses_retry", thread: thread, body: "turn_id=\(turn): stream connection failed; waiting to retry")
        try check(provider.retrying[thread] == turn, "网络等待日志识别")
        let frames = DeviceFrames.all(["tasks": ["items": [["id": turn, "name": "测试任务", "status": "RECONNECTING", "tokens": 123]]]])
        try check(String(decoding: frames[1], as: UTF8.self).contains("X=WAIT"), "重连编码为红色 WAIT")
        let defaults: JSONObject = ["agent": "codex", "bleEnabled": true, "completionHours": 48.0, "pushInterval": 0.25, "accountInterval": 2.0]
        for invalid: JSONObject in [["accountInterval": 1], ["bleEnabled": 1], ["completionHours": 169], ["agent": "unregistered"]] {
            var rejected = false
            do { _ = try NativeRuntime.validate(invalid, current: defaults) } catch { rejected = true }
            try check(rejected, "拒绝无效设置 \(invalid.keys.first!)")
        }
        let partialURL = URL(fileURLWithPath: path)
        let record = try JSONSerialization.data(withJSONObject: ["type": "event_msg", "payload": ["type": "task_started", "turn_id": "partial", "started_at": now + 2]])
        try record.write(to: partialURL)
        provider.tail(retention: 48 * 3600)
        try check(provider.turns["partial"] == nil, "不消费未完成的日志行")
        var complete = record; complete.append(10); try complete.write(to: partialURL)
        provider.tail(retention: 48 * 3600)
        try check(provider.turns["partial"] != nil, "日志行完成后立即消费")
        let persistent = NativeCodexProvider(root: root)
        _ = persistent.taskStatus(retention: 48 * 3600)
        try persistent.hide("partial")
        let reloaded = NativeCodexProvider(root: root)
        try check(reloaded.hiddenCount == 1 && reloaded.hidden(reloaded.turns["partial"] ?? [:]), "隐藏记录与任务缓存跨重启保留")
        try reloaded.restoreHidden()
        try check(NativeCodexProvider(root: root).hiddenCount == 0, "恢复隐藏记录持久化")
        let ocRoot = root.appendingPathComponent("oc")
        try FileManager.default.createDirectory(at: ocRoot, withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(ocRoot.appendingPathComponent("opencode.db").path, &db) == SQLITE_OK else { throw NativeError("Test DB open failed") }
        defer { sqlite3_close(db) }
        func sql(_ source: String) throws {
            guard sqlite3_exec(db, source, nil, nil, nil) == SQLITE_OK else { throw NativeError("Test SQL failed") }
        }
        let ms = Int(now * 1000)
        try sql("CREATE TABLE session(id TEXT,title TEXT,directory TEXT,time_updated INTEGER,time_archived INTEGER,parent_id TEXT,tokens_input INTEGER,tokens_output INTEGER,tokens_reasoning INTEGER,tokens_cache_read INTEGER,tokens_cache_write INTEGER); CREATE TABLE message(id TEXT,session_id TEXT,time_created INTEGER,data TEXT); INSERT INTO session VALUES('ses_test','OpenCode 测试','/test',\(ms),NULL,NULL,10,20,3,4,5); INSERT INTO message VALUES('user','ses_test',\(ms-1000),'{\"role\":\"user\",\"time\":{\"created\":\(ms-1000)}}'); INSERT INTO message VALUES('assistant','ses_test',\(ms),'{\"role\":\"assistant\",\"finish\":\"stop\",\"time\":{\"created\":\(ms),\"completed\":\(ms)}}');")
        let oc = NativeOpenCodeProvider(root: ocRoot, hiddenURL: root.appendingPathComponent("oc-hidden.json"))
        func ocItems() -> [JSONObject] { oc.taskStatus(retention: 48 * 3600)["items"] as? [JSONObject] ?? [] }
        try check(string(ocItems().first?["status"]) == "COMPLETED" && number(ocItems().first?["tokens"]) == 42, "OpenCode 完成状态和真实用量")
        oc.live = ["ses_test": ["type": "busy"]]
        try check(string(ocItems().first?["status"]) == "ACTIVE", "OpenCode 运行状态优先")
        oc.waiting = ["ses_test"]
        try check(string(ocItems().first?["status"]) == "WAITING", "OpenCode 待确认红色")
        oc.waiting = []; oc.live = ["ses_test": ["type": "retry"]]
        try check(string(ocItems().first?["status"]) == "RECONNECTING", "OpenCode 重连红色")
        try oc.hide("oc:ses_test")
        try check(ocItems().isEmpty, "OpenCode 独立隐藏记录")
        try sql("INSERT INTO message VALUES('new_user','ses_test',\(ms+1000),'{\"role\":\"user\",\"time\":{\"created\":\(ms+1000)}}');")
        try check(!ocItems().isEmpty, "OpenCode 新一轮重新显示")
        let ocFrames = DeviceFrames.all(["tasks": ["items": ocItems()]], agent: "opencode")
        try check(ocFrames.allSatisfy { String(decoding: $0, as: UTF8.self).hasPrefix("AG=opencode;") }, "每个蓝牙帧隔离 Agent")
        try check(string(try NativeRuntime.validate(["agent": "opencode"], current: defaults)["agent"]) == "opencode", "桌面支持选择 OpenCode")
        let namesRoot = root.appendingPathComponent("question-names")
        let names = NativeCodexProvider(root: namesRoot, persist: false)
        func nameEvent(_ type: String, _ payload: JSONObject) { names.consume(["type": type, "payload": payload], path: "question.jsonl", mtime: now, now: now) }
        func nameItem() -> JSONObject { (names.taskStatus(retention: 48 * 3600)["items"] as? [JSONObject])?.first ?? [:] }
        nameEvent("event_msg", ["type": "task_started", "turn_id": "name-turn", "thread_id": "name-thread", "started_at": now])
        try check(string(nameItem()["name"]) == "Codex task", "无问题时回退原会话标题")
        nameEvent("response_item", ["type": "message", "role": "user", "content": [["type": "input_text", "text": "<environment_context>secret path</environment_context>"], ["type": "input_text", "text": "根据当前问题\n  实时更新名称"]]])
        try check(string(nameItem()["name"]) == "根据当前问题 实时更新名称", "最新问题命名并过滤环境信息")
        nameEvent("event_msg", ["type": "user_message", "message": "再加一个设置按钮"])
        try check(string(nameItem()["name"]) == "再加一个设置按钮" && string(nameItem()["id"]) == "name-turn", "同一轮追加问题立即改名且 ID 不变")
        nameEvent("response_item", ["type": "message", "role": "assistant", "content": [["type": "text", "text": "不应成为任务名"]]])
        try check(string(nameItem()["name"]) == "再加一个设置按钮", "助手输出不改名")
        try names.hide("name-turn")
        nameEvent("event_msg", ["type": "user_message", "message": "名称变更不解除隐藏"])
        try check(nameItem().isEmpty, "改名不影响隐藏记录")
        try names.restoreHidden()
        nameEvent("event_msg", ["type": "task_complete", "turn_id": "name-turn", "completed_at": now])
        nameEvent("event_msg", ["type": "user_message", "message": "新一轮在开始事件前到达"])
        nameEvent("event_msg", ["type": "task_started", "turn_id": "name-next", "thread_id": "name-thread", "started_at": now + 1])
        try check(string(nameItem()["name"]) == "新一轮在开始事件前到达", "支持用户消息先于 task_started")
        try writeObject(["turns": names.turns], to: namesRoot.appendingPathComponent("codex-tip-task-state.json"))
        let namesReloaded = NativeCodexProvider(root: namesRoot, persist: false)
        try check(string(namesReloaded.turns["name-next"]?["display_name"]) == "新一轮在开始事件前到达", "显示名称跨重启保留")
        try check(NativeCodexProvider.questionName("# AGENTS.md instructions for /tmp\n<INSTRUCTIONS>rules</INSTRUCTIONS>") == nil, "过滤 AGENTS 注入信息")
        try check(NativeCodexProvider.questionName("## Active file: path\n## My request for Codex:\n 修复登录错误") == "修复登录错误", "IDE 问题提取")
        try check(NativeCodexProvider.questionName(String(repeating: "测试", count: 100))?.count == 64, "长问题按字符截取")
        print("All native tests passed")
    }
}
