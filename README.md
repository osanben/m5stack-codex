# Codex Tip — M5Stack CoreS3 实时仪表盘

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

首次开机或轻触屏幕后，设备会开启配置热点：

- SSID：`CODEX-TIP-SETUP`
- 密码：`codex-tip`
- 在浏览器打开 `http://192.168.4.1`，填写 Wi‑Fi 与 `http://<MAC-LAN-IP>:8765/status`。

固件优先使用已保存的配置；没有保存配置时会尝试 ESP32 现存的 Wi‑Fi station 配置。触摸屏幕可再次开启配置页面。

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
