import SwiftUI
import AppKit

struct TaskItem: Decodable, Identifiable {
    var id: String
    var name: String
    var tokens: Int
    var status: String
    var color: Color {
        switch status {
        case "COMPLETED": return .yellow
        case "WAITING", "RECONNECTING": return .red
        case "INTERRUPTED": return .gray
        default: return .green
        }
    }
    var label: String {
        ["ACTIVE": "运行中", "COMPLETED": "已完成", "WAITING": "等待确认",
         "RECONNECTING": "等待网络", "INTERRUPTED": "已中断"][status] ?? status
    }
}
struct Preferences: Codable, Equatable {
    var agent = "codex"
    var bleEnabled = true
    var completionHours = 48.0
    var pushInterval = 0.25
    var accountInterval = 2.0
}
struct Device: Decodable { var state: String; var address: String; var error: String }
struct AgentInfo: Decodable, Identifiable { var id: String; var name: String; var available: Bool }
struct TaskList: Decodable { var active: Int; var items: [TaskItem] }
struct Usage: Decodable { var lifetimeTokens: Int }
struct Status: Decodable { var plan: String; var tasks: TaskList; var usage: Usage; var error: String? }
struct Snapshot: Decodable {
    var settings: Preferences
    var device: Device
    var status: Status
    var hiddenCount: Int
    var agents: [AgentInfo]
}

@MainActor final class Model: ObservableObject {
    @Published var snapshot: Snapshot?
    @Published var preferences = Preferences()
    @Published var message = ""
    @Published var connected = false
    @Published var busy = false
    private var loaded = false
    private var fetching = false
    let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Agent Display")

    func request(_ path: String, body: Data? = nil) async throws -> Data {
        let token = try String(contentsOf: folder.appendingPathComponent("control-token"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8765" + path)!)
        request.timeoutInterval = 5
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "AgentDisplay", code: 1, userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "请求失败"])
        }
        return data
    }

    func refresh() async {
        guard !fetching else { return }
        fetching = true
        defer { fetching = false }
        do {
            let result = try JSONDecoder().decode(Snapshot.self, from: await request("/api/desktop"))
            snapshot = result
            if !loaded { preferences = result.settings; loaded = true }
            if !connected && loaded { message = "后台已连接" }
            connected = true
        } catch {
            connected = false
            message = "后台未连接：\(error.localizedDescription)"
        }
    }

    func save() async {
        busy = true
        defer { busy = false }
        do {
            _ = try await request("/api/settings", body: JSONEncoder().encode(preferences))
            message = "设置已保存并生效"
            await refresh()
        } catch { message = error.localizedDescription }
    }

    func action(_ path: String, id: String? = nil) async {
        busy = true
        defer { busy = false }
        do {
            let body = try JSONSerialization.data(withJSONObject: id.map { ["id": $0] } ?? [:])
            _ = try await request(path, body: body)
            message = "操作已完成"
            await refresh()
        } catch { message = error.localizedDescription }
    }

    func startService() {
        NativeRuntime.shared.start()
        message = "正在连接应用内的原生后台…"
    }
}

struct ContentView: View {
    @StateObject private var model = Model()
    @State private var selection = "概览"
    private let pages = [("概览", "rectangle.grid.2x2"), ("任务", "list.bullet.rectangle"),
                         ("Agent", "cpu"), ("设置", "slider.horizontal.3")]
    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(pages, id: \.0) { page in Label(page.0, systemImage: page.1).tag(page.0) }
            }
            .navigationTitle("Agent Display")
            .navigationSplitViewColumnWidth(180)
        } detail: {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text(selection).font(.largeTitle.bold())
                    Spacer()
                    Circle().fill(model.connected ? .green : .orange).frame(width: 8, height: 8)
                    Text(model.connected ? "后台在线" : "后台未连接").foregroundStyle(.secondary)
                }
                if !model.connected {
                    HStack {
                        Text("后台服务未连接。已有设备设置不会被清除。")
                        Button("启动后台") { model.startService() }
                    }.padding().background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch selection {
                        case "设置": settings
                        case "Agent": agents
                        case "任务": tasks
                        default: overview
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if !model.message.isEmpty {
                    Text(model.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }.padding(28)
        }
        .frame(minWidth: 850, minHeight: 560)
        .task {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    var overview: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                metric("运行任务", "\(model.snapshot?.status.tasks.active ?? 0)", "bolt.fill")
                metric("屏幕 Token 合计", number(model.snapshot?.status.tasks.items.reduce(0) { $0 + $1.tokens } ?? 0), "chart.bar.fill")
                metric("套餐", model.snapshot?.status.plan ?? "—", "person.crop.circle")
            }
            GroupBox("M5Stack · 蓝牙") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(deviceLabel).font(.title3.weight(.medium))
                    Text(model.snapshot?.device.address ?? "等待设备").font(.caption.monospaced()).foregroundStyle(.secondary)
                    if let error = model.snapshot?.device.error, !error.isEmpty { Text(error).foregroundStyle(.red) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            if let error = model.snapshot?.status.error, !error.isEmpty {
                Text("账户数据暂未刷新：\(error)").font(.caption).foregroundStyle(.orange)
            }
            tasks
        }
    }
    var deviceLabel: String {
        ["connected": "已连接", "scanning": "正在寻找 CODEX-TIP…", "paused": "蓝牙推送已暂停",
         "connecting": "正在连接设备…", "error": "连接异常，自动重试中", "starting": "正在启动"][model.snapshot?.device.state ?? ""] ?? "等待后台"
    }
    func metric(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).foregroundStyle(.secondary)
            Text(value).font(.title.bold()).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
    var tasks: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("屏幕任务").font(.headline)
                Spacer()
                Button("恢复隐藏任务（\(model.snapshot?.hiddenCount ?? 0)）") {
                    Task { await model.action("/api/tasks/restore") }
                }.disabled(!model.connected || model.busy || model.snapshot?.hiddenCount == 0)
            }
            if model.snapshot?.status.tasks.items.isEmpty != false {
                Text("暂无可显示的任务").foregroundStyle(.secondary).padding(.vertical, 30)
            }
            ForEach(model.snapshot?.status.tasks.items ?? []) { item in
                HStack(spacing: 14) {
                    Circle().fill(item.color).frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.name).font(.headline)
                        Text("\(item.label) · \(number(item.tokens)) tokens").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("隐藏") { Task { await model.action("/api/tasks/hide", id: item.id) } }
                        .disabled(!model.connected || model.busy)
                }.padding(14).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            }
            Text("与设备同步，最多显示 4 项。隐藏只影响仪表盘，同一任务新一轮运行时会重新出现。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    var agents: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(model.snapshot?.agents ?? []) { agent in
                GroupBox("\(agent.name) · 已接入") {
                    Text("已注册的本机 Agent 数据源，使用统一任务与设备协议。")
                        .frame(maxWidth: .infinity, alignment: .leading).padding()
                }
            }
            GroupBox("OpenCode · 待接入") {
                Text("已预留 AgentProvider 接口。本版本尚未连接 OpenCode，不会生成模拟任务或用量。")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding()
            }
        }
    }
    var settings: some View {
        VStack(alignment: .leading, spacing: 22) {
            Picker("设备数据源", selection: $model.preferences.agent) {
                ForEach(model.snapshot?.agents ?? []) { agent in Text(agent.name).tag(agent.id) }
            }
            Toggle("启用蓝牙推送", isOn: $model.preferences.bleEnabled)
            HStack { Text("完成任务保留（小时）"); Spacer(); TextField("48", value: $model.preferences.completionHours, format: .number).frame(width: 100) }
            Text("范围：1–168 小时；运行中任务优先显示。").font(.caption).foregroundStyle(.secondary)
            HStack { Text("蓝牙刷新间隔（秒）"); Spacer(); TextField("0.25", value: $model.preferences.pushInterval, format: .number).frame(width: 100) }
            HStack { Text("账户刷新间隔（秒）"); Spacer(); TextField("2", value: $model.preferences.accountInterval, format: .number).frame(width: 100) }
            Text("蓝牙 0.1–10 秒；账户 2–300 秒。设置保存后立即生效，关闭窗口后后台继续运行。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("保存设置") { Task { await model.save() } }.buttonStyle(.borderedProminent)
                    .disabled(!model.connected || model.busy)
                Button("打开日志") { NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Agent Display.log")) }
                Button("设置文件夹") { NSWorkspace.shared.open(model.folder) }
            }
        }.textFieldStyle(.roundedBorder)
    }
    func number(_ value: Int) -> String { value.formatted(.number.notation(.compactName)) }
}

final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NativeRuntime.shared.start()
        if CommandLine.arguments.contains("--background") { NSApp.hide(nil) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { NativeRuntime.shared.stop() }
}

struct TrayMenu: View {
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Button("打开 Agent Display") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Divider()
        Button("退出（停止设备推送）") { NSApp.terminate(nil) }
    }
}

struct AgentDisplayApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) var delegate
    var body: some Scene {
        WindowGroup("Agent Display", id: "main") { ContentView() }
            .defaultSize(width: 980, height: 660)
        MenuBarExtra("Agent Display", systemImage: "display") { TrayMenu() }
    }
}
