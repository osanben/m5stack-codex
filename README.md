# Codex Tip — M5Stack CoreS3 实时仪表盘

## Mac 桌面应用：Agent Display

原生 SwiftUI 桌面应用，任务解析、SQLite 读取、账户 RPC、HTTP 接口和 CoreBluetooth 推送全部在应用内运行，不依赖 Python 服务。关闭窗口后继续在菜单栏运行；菜单栏选择退出才停止推送。

当前 Mac 已安装到 `~/Applications/Agent Display.app`，可直接从 Finder 打开。

```sh
python3 desktop/build_app.py
open "dist/Agent Display.app"
"dist/Agent Display.app/Contents/MacOS/AgentDisplay" --self-test
```

运行需要 macOS 13+、Codex 应用或 CLI，以及系统蓝牙权限。首次打开请允许 Agent Display 使用蓝牙；完成通知可选。编译需要 Xcode Command Line Tools 和 Python 3（仅用于构建脚本，应用运行不需要 Python 或 `.venv`）。这是本机构建、临时签名版本，尚未做 Developer ID 公证。后台地址为 `127.0.0.1:8765`。日志为 `~/Library/Logs/Agent Display.log`。

本机原 Python LaunchAgent `com.codex.tip.bridge` 已停止并禁用，源码和配置保留以便回退，不要与桌面应用同时启动。原设置、完成任务状态和隐藏记录沿用原文件；迁移前备份位于 `~/Library/Application Support/Agent Display/migration-native-20260922/`。桌面应用登录启动由 `com.codex.tip.desktop` LaunchAgent 负责。

- **概览**：设备连接状态、套餐、可见任务 token 合计、账户错误。
- **任务**：与屏幕同步的 4 个任务、隐藏任务、恢复隐藏记录。
- **设置**：蓝牙开关、完成状态保留小时数、推送间隔、账户刷新间隔，保存后立即生效。
- **Agent**：Codex 和 OpenCode 已接入。设备同时保留两个独立任务页；设置中的 Agent 选择只影响桌面查看与恢复隐藏操作。

设置保存到 `~/Library/Application Support/Agent Display/settings.json`。同目录的 `control-token` 仅允许当前用户读取，桌面控制接口同时检查 loopback 来源和 Bearer token，不开放跨域。旧 `/status` 和 BLE 数据格式保持兼容。

原生扩展入口是 `desktop/NativeCore.swift` 的 `NativeAgentProvider`：提供任务状态、隐藏和恢复接口。OpenCode 实现在 `desktop/NativeOpenCode.swift`，只读查询 `~/.local/share/opencode/opencode.db` 并通过本地服务获取运行、重试及待确认状态。OpenCode 读取使用独立队列，不阻塞 Codex 或 BLE；完成任务同样保留 48 小时。蓝牙每帧携带 `AG=codex` 或 `AG=opencode`，任务列表、用量和隐藏记录彼此隔离。OpenCode 的套餐额度不伪造，也不复用 Codex 的额度。

应用启动本机 `~/.opencode/bin/opencode serve --hostname 127.0.0.1 --port 4096`，使用控制令牌做 Basic Auth；不会提交提示词、批准权限或执行 Agent 任务。已存在且可访问的服务会被复用；退出应用只停止自己启动的服务。原有独立终端不会关闭。通过 Agent 页的“打开 OpenCode 终端”连接共享服务（亦可打开应用包内的 `Contents/Resources/OpenCode.command`）。连接机制见 [OpenCode Server 文档](https://dev.opencode.ai/docs/server/)。

独立 TUI 的运行时权限提示不属于共享服务，数据库只能提供历史和近期活动；无法确认的状态以灰色显示，不伪装为完成。要准确显示待确认、网络重试，请使用上述共享服务入口。隐藏仅影响显示，不调用 OpenCode 删除会话接口；新一轮用户输入后重新显示。

原生自测涵盖任务颜色、异步确认、Esc 中断、48 小时保留、隐藏/新一轮恢复、重连红色、设置校验和不完整日志行。`--snapshot` 可只读输出当前任务，不连接蓝牙、不修改状态文件。旧 Python 回归测试仍保留：`.venv/bin/python -m unittest discover -s bridge -p 'test_*.py'`。

这是给已连接 **M5Stack CoreS3（ESP32-S3）** 的固件和本机只读桥接服务。屏幕实时显示：

- Codex 用量窗口、下次重置时间、套餐；
- 可见任务 token 合计与累计用量；
- 当前活跃任务、最近任务标题；
- 已获得的限额重置次数。

运行中的任务为绿色并保留旋转动画，完成后以黄色状态保留 48 小时（服务重启后仍保留）。待确认和重连仍为红色，中断仍为灰色。屏幕最多显示 4 个任务，运行中的任务优先，其余位置显示最近完成的任务；同一任务开始新一轮时优先显示运行状态。

账户数据来自本机 `codex app-server` 的只读 RPC：`account/rateLimits/read`、`account/usage/read`、`account/read`。任务来自本地会话日志和只读 SQLite 查询。额度查询在独立队列运行，正常缓存 2 秒，超时不会阻塞任务推送。它不向设备传输 OpenAI 密钥，也不提供“消费重置额度”的写操作。

## 1. 启动桌面应用

在运行 Codex 的 Mac 上：

```sh
open "$HOME/Applications/Agent Display.app"
```

查看 Mac 在局域网内的地址（示例）：

```sh
ipconfig getifaddr en0
```

设备和 Mac 可在同一个 Wi‑Fi，也可直接使用 BLE。防火墙若询问，请仅允许本地网络连接；不要将 8765 端口暴露到互联网。

## 2. 编译与烧录

安装 PlatformIO 后运行：

```sh
pio device list
# 确认序列号 44:1B:F6:E3:9C:C0 对应 M5Stack 后再烧录；端口可能变化。
pio run -t upload --upload-port /dev/cu.usbmodem1101
```

开机后，设备会开启配置热点：

- SSID：`CODEX-TIP-SETUP`
- 密码：`codex-tip`
- 在浏览器打开 `http://192.168.4.1`，填写 Wi‑Fi 与 `http://<MAC-LAN-IP>:8765/status`。

固件优先使用已保存的配置；没有保存配置时会尝试 ESP32 现存的 Wi‑Fi station 配置。

## 长按隐藏任务（蓝牙）

设备有 Codex → OpenCode → 电源 → 设置四个页面，左右滑手动循环切换；从 Codex 页右滑可直接进入设置。设置页提供自动切页开启/暂停按钮，以及 Codex、OpenCode、电源页的直达按钮。自动切页开关写入设备 NVS，重启后保留；保存失败会提示，且不改变原开关状态。按钮在松手时触发，滑动、多指和长按不会触发按钮。

自动轮换开启时，仅 Codex 和 OpenCode 两页每 5 秒轮换；触摸期间暂停，松手后重新计时 5 秒。电源页和设置页只手动进入，停留期间不自动切页；手动回到任务页后按开关状态决定是否继续轮换。暂停自动轮换不影响手动切页、任务更新或蓝牙连接。电源页右上角显示电量，页内显示正在充电 / 电池放电 / 电池待机 / 未检测到电池，以及 USB 接入状态、电池电压、USB 输入电压、VSYS 系统电压和运行时间，每秒刷新。USB 接入不等于正在充电，也不将待机误标为充满。CoreS3 没有可用的实时电流传感器，因此电流和功率明确显示“未支持”，不使用充电限流设置值或占位零值代替测量。

滑动超过 60 像素切页；多指、明显纵向移动和长按不会触发切页。滑动会取消任务长按隐藏，电源页不会发送隐藏指令。切页不影响后台 BLE 任务更新。手势逻辑可在 Mac 自测：`c++ -std=c++11 -Iinclude test/swipe_navigation.cpp -o /tmp/codex-tip-swipe-test && /tmp/codex-tip-swipe-test`。

按住任务气泡约 1 秒即可从状态屏列表隐藏；拖动或多指触摸会取消此次操作。操作只隐藏仪表盘条目，不删除 Codex 会话、不停止任务。隐藏记录保存在 Mac 的 `~/.codex/codex-tip-dismissed.json`，重启后仍有效；同一线程开始新一轮任务时重新显示。右上角 token 合计随可见列表更新。

## 蓝牙模式（默认启用）

烧录后设备广播名为 `CODEX-TIP` 的 BLE 服务。桌面应用通过 CoreBluetooth 自动发现并连接它，然后默认每 0.25 秒写入只读仪表盘状态。因此不需要填 Wi‑Fi、Bridge URL 或将端口开放到网络。显示左上角出现 `BLE LIVE` 即表示成功。桌面应用迁移不需要重新烧录。

## 实时内存监控

固件每 5 秒输出一组 `[MEM]` 日志，分别统计内部 RAM 和 PSRAM 的可分配堆（单位：字节）。这不是芯片全部物理内存，也不包括已被静态段占用的空间。

```sh
.venv/bin/pio device monitor --port /dev/cu.usbmodem1101 --baud 115200
```

`total`：堆总量；`used` / `free`：当前已用 / 剩余；`min_free`：启动以来低水位；`largest`：最大连续空闲块；`used_pct`：堆使用百分比。新增功能时重点对比 `free`、`min_free` 和 `largest`。PSRAM 未启用或不可用时显示为 0。按 Ctrl+C 退出。串口号可能变化，先用 `.venv/bin/pio device list` 确认 M5Stack 的 USB 序列号 `44:1B:F6:E3:9C:C0`。

## 验证桥接服务

```sh
curl http://127.0.0.1:8765/status
```

返回 JSON 后，M5Stack 每 0.5 秒拉取一次并渲染；账户与额度数据在桥接端缓存 2 秒，但本地任务生命周期会在每次更新时重新读取。官方 Codex App Server 对 `rateLimits`、账户 token 用量、任务列表的定义见 [OpenAI 文档](https://learn.chatgpt.com/docs/app-server)。
