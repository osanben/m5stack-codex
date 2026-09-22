# Codex Tip — M5Stack CoreS3 实时仪表盘

## Mac 桌面应用：Agent Display

原生 SwiftUI 界面管理 Python 后台，关闭窗口不会停止 M5Stack 推送。

当前 Mac 已安装到 `~/Applications/Agent Display.app`，可直接从 Finder 打开。

```sh
python3 desktop/build_app.py
open "dist/Agent Display.app"
```

需要 macOS 13+、Xcode Command Line Tools，以及已安装并运行的桥接 LaunchAgent（本项目当前 Mac 已配置）。这是本机构建版本，尚未打包独立 Python 运行时或做 Developer ID 公证；请保留项目目录和 `.venv`。当前后台地址为 `127.0.0.1:8765`。

- **概览**：设备连接状态、套餐、可见任务 token 合计、账户错误。
- **任务**：与屏幕同步的 4 个任务、隐藏任务、恢复隐藏记录。
- **设置**：蓝牙开关、完成状态保留小时数、推送间隔、账户刷新间隔，保存后立即生效。
- **Agent**：当前接入 Codex。OpenCode 尚未实现，界面明确显示待接入。

设置保存到 `~/Library/Application Support/Agent Display/settings.json`。同目录的 `control-token` 仅允许当前用户读取，桌面控制接口同时检查 loopback 来源和 Bearer token，不开放跨域。旧 `/status` 和 BLE 数据格式保持兼容。

扩展入口是 `bridge/desktop_runtime.py` 的 `AgentProvider`：实现 `status()`、`hide()`、`restore_hidden()`，并注册到 `RUNTIME.providers`，桌面选择器自动列出已注册的数据源。`status()` 返回现有 dashboard schema；任务 ID 必须稳定、唯一且能通过 BLE 传输。当前一次选择一个 Agent。本次提取了 provider 边界；Codex 原有日志解析仍保留在桥接模块中，避免改变已验证的任务状态行为。

后台/API 测试：`.venv/bin/python -m unittest discover -s bridge -p 'test_*.py'`。

这是给已连接 **M5Stack CoreS3（ESP32-S3）** 的固件和本机只读桥接服务。屏幕实时显示：

- Codex 用量窗口、下次重置时间、套餐；
- 当日与累计 token；
- 当前活跃任务、最近任务标题；
- 已获得的限额重置次数。

任务完成后会以绿色状态保留 72 小时（服务重启后仍保留）。屏幕最多显示 4 个任务，运行中的任务优先，其余位置显示最近完成的任务；同一任务开始新一轮时优先显示运行状态。

数据来自本机 `codex app-server` 的只读 RPC：`account/rateLimits/read`、`account/usage/read`、`account/read` 和 `thread/list`。它不读取或传输 OpenAI 密钥，也不提供“消费重置额度”的写操作。

## 1. 启动桥接服务

在运行 Codex 的 Mac 上：

```sh
python3 bridge/codex_tip_bridge.py
```

查看 Mac 在局域网内的地址（示例）：

```sh
ipconfig getifaddr en0
```

设备和 Mac 可在同一个 Wi‑Fi，也可直接使用 BLE。防火墙若询问，请仅允许本地网络连接；不要将 8765 端口暴露到互联网。

## 2. 编译与烧录

安装 PlatformIO 后运行：

```sh
pio run -t upload --upload-port /dev/cu.usbmodem1201
```

开机后，设备会开启配置热点：

- SSID：`CODEX-TIP-SETUP`
- 密码：`codex-tip`
- 在浏览器打开 `http://192.168.4.1`，填写 Wi‑Fi 与 `http://<MAC-LAN-IP>:8765/status`。

固件优先使用已保存的配置；没有保存配置时会尝试 ESP32 现存的 Wi‑Fi station 配置。

## 长按隐藏任务（蓝牙）

按住任务气泡约 1 秒即可从状态屏列表隐藏；拖动或多指触摸会取消此次操作。操作只隐藏仪表盘条目，不删除 Codex 会话、不停止任务。隐藏记录保存在 Mac 的 `~/.codex/codex-tip-dismissed.json`，重启后仍有效；同一线程开始新一轮任务时重新显示。右上角 token 合计随可见列表更新。

## 蓝牙模式（默认启用）

烧录后设备广播名为 `CODEX-TIP` 的 BLE 服务。本机桥接以 BLE 中心方式自动发现并连接它，然后每 0.25 秒写入只读仪表盘状态。因此不需要填 Wi‑Fi、Bridge URL 或将端口开放到网络。显示左上角出现 `BLE LIVE` 即表示成功。

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
