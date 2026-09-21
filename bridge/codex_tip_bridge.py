#!/usr/bin/env python3
"""Read-only LAN bridge from Codex App Server to an M5Stack dashboard."""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import queue
import sqlite3
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

try:
    from bleak import BleakClient, BleakScanner
except ImportError:  # BLE stays optional for HTTP-only installations.
    BleakClient = BleakScanner = None

BLE_SERVICE_UUID = "5f6d0001-7f62-4da0-99e6-401b1de91a00"
BLE_STATUS_UUID = "5f6d0002-7f62-4da0-99e6-401b1de91a00"
BLE_ACTION_UUID = "5f6d0003-7f62-4da0-99e6-401b1de91a00"
STATE_DIR = Path.home() / ".codex"
TASK_STATE_PATH = STATE_DIR / "codex-tip-task-state.json"
STATUS_CACHE_PATH = STATE_DIR / "codex-tip-status.json"
ACTIVE_IDLE_SECONDS = 15 * 60
APP_SERVER_TIMEOUT_SECONDS = 15
# Keep completed tasks visible long enough to use the dashboard as a recent
# activity display, not only as a transient completion notification.
COMPLETION_DISPLAY_SECONDS = 72 * 60 * 60
INTERRUPTION_DISPLAY_SECONDS = 30 * 60
# Lifecycle events are local files, so this is the maximum normal delay before
# a task transition is sent to a connected display.
LIVE_PUSH_SECONDS = 0.25
# Account/usage RPCs are slower and independent of task lifecycle state.
ACCOUNT_CACHE_SECONDS = 2.0


def read_json_file(path: Path, fallback: Any) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return fallback


def write_json_file(path: Path, value: Any) -> None:
    """Atomically replace a small local cache; a power loss leaves the old file."""
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_suffix(path.suffix + ".tmp")
        temporary.write_text(json.dumps(value, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
        os.replace(temporary, path)
    except OSError:
        pass


class CodexClient:
    def __init__(self) -> None:
        # start() performs the initial JSON-RPC handshake through request().
        self.lock = threading.RLock()
        self.proc: subprocess.Popen[str] | None = None
        self.next_id = 1
        self.responses: queue.Queue[dict[str, Any]] = queue.Queue()

    def drain_stdout(self, proc: subprocess.Popen[str]) -> None:
        assert proc.stdout
        for line in proc.stdout:
            try:
                self.responses.put(json.loads(line))
            except json.JSONDecodeError:
                continue

    def start(self) -> None:
        # A separate, read-only App Server gives stable account and history
        # data without taking ownership of the GUI client's live connection.
        command = ["codex", "app-server", "--stdio"]
        self.proc = subprocess.Popen(
            command, stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1,
        )
        self.responses = queue.Queue()
        threading.Thread(target=self.drain_stdout, args=(self.proc,), name="codex-tip-app-server", daemon=True).start()
        self.request("initialize", {
            "clientInfo": {"name": "codex_tip", "title": "Codex Tip M5Stack bridge", "version": "1.0.0"},
            "capabilities": {"experimentalApi": True},
        })
        self.notify("initialized", {})

    def notify(self, method: str, params: dict[str, Any]) -> None:
        assert self.proc and self.proc.stdin
        self.proc.stdin.write(json.dumps({"method": method, "params": params}) + "\n")
        self.proc.stdin.flush()

    def request(self, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        with self.lock:
            if not self.proc or self.proc.poll() is not None:
                self.start()
            assert self.proc and self.proc.stdin and self.proc.stdout
            request_id = self.next_id
            self.next_id += 1
            self.proc.stdin.write(json.dumps({"id": request_id, "method": method, "params": params or {}}) + "\n")
            self.proc.stdin.flush()
            while True:
                try:
                    payload = self.responses.get(timeout=APP_SERVER_TIMEOUT_SECONDS)
                except queue.Empty:
                    # Do not let a stalled local App Server freeze the M5's
                    # event-derived task display. A later request recreates it.
                    self.proc.terminate()
                    self.proc = None
                    raise RuntimeError(f"Codex App Server timed out during {method}")
                if payload.get("id") == request_id:
                    if "error" in payload:
                        raise RuntimeError(payload["error"].get("message", "Codex App Server error"))
                    return payload.get("result", {})
            raise RuntimeError("Codex App Server stopped")


CLIENT = CodexClient()
CACHE: dict[str, Any] = {"at": 0.0, "data": read_json_file(STATUS_CACHE_PATH, None), "error": "Starting…", "refreshing": False}
CACHE_LOCK = threading.Lock()
TASK_LOCK = threading.Lock()
DISMISSED_PATH = STATE_DIR / "codex-tip-dismissed.json"
DISMISSED = read_json_file(DISMISSED_PATH, {})


def task_hidden(item: dict[str, Any]) -> bool:
    cutoff = DISMISSED.get(item.get("thread_id", ""))
    return cutoff is not None and int(item.get("started_at") or 0) <= cutoff


def handle_device_action(_characteristic: Any, packet: bytearray) -> None:
    message = bytes(packet).decode("utf-8", errors="replace")
    if not message.startswith("HIDE="):
        return
    turn_id = message[5:]
    with TASK_LOCK:
        item = TRACKER.turns.get(turn_id)
        if not item or not item.get("thread_id"):
            return
        thread_id = item["thread_id"]
        DISMISSED[thread_id] = max(DISMISSED.get(thread_id, 0), int(item.get("started_at") or 0))
        write_json_file(DISMISSED_PATH, DISMISSED)
    print(f"Dashboard task hidden: {turn_id}", flush=True)


class ReconnectTracker:
    """Read actual retry/output events, never arbitrary tool or message text."""
    def __init__(self) -> None:
        self.cursor: int | None = None
        self.reconnecting: dict[str, str] = {}

    def consume(self, target: str, thread_id: str, body: str) -> None:
        turn = re.search(r'\bturn_id=([0-9a-f-]{36})', body)
        if not turn or not thread_id:
            return
        if target == "codex_core::responses_retry" and re.search(
                r': (?:stream disconnected - retrying sampling request \(|stream connection failed; waiting to retry\b)', body):
            self.reconnecting[thread_id] = turn.group(1)
        elif target == "codex_core::stream_events_utils" and re.search(r': Output item item_type="[a-z_]+" item_id="[^"\n]+"$', body):
            self.reconnecting.pop(thread_id, None)

    def update(self) -> None:
        database = Path.home() / ".codex" / "logs_2.sqlite"
        try:
            with sqlite3.connect(f"file:{database}?mode=ro", uri=True, timeout=0.05) as db:
                maximum = db.execute("SELECT COALESCE(MAX(id),0) FROM logs").fetchone()[0]
                if self.cursor is None or maximum < self.cursor:
                    self.cursor = max(0, maximum - 20000)
                    self.reconnecting.clear()
                rows = db.execute("SELECT id,target,thread_id,feedback_log_body FROM logs "
                                  "WHERE id>? AND id<=? AND target IN (?,?) ORDER BY id LIMIT 2000",
                                  (self.cursor, maximum, "codex_core::responses_retry", "codex_core::stream_events_utils")).fetchall()
                for _, target, thread_id, body in rows:
                    self.consume(target, thread_id, body or "")
                self.cursor = rows[-1][0] if len(rows) == 2000 else maximum
        except sqlite3.Error:
            pass


RECONNECT_TRACKER = ReconnectTracker()


class TaskTracker:
    """Tail Codex rollout events so active/completed turns are not guessed."""
    def __init__(self) -> None:
        self.files: dict[Path, tuple[int, int]] = {}
        self.turns: dict[str, dict[str, str]] = {}
        self.ready = False
        self.file_turns: dict[Path, str] = {}
        self.pending_confirmations: dict[str, str] = {}
        self.async_confirmations: set[str] = set()
        self.notice = ""
        self.notice_until = 0.0
        # One completed entry per thread. A turn may finish while another task
        # is also completing; each green bubble gets its own display window.
        self.recent_completed: dict[str, dict[str, Any]] = {}
        saved = read_json_file(TASK_STATE_PATH, {})
        if isinstance(saved, dict) and isinstance(saved.get("turns"), dict):
            self.turns = {str(turn_id): dict(data) for turn_id, data in saved["turns"].items()
                          if isinstance(data, dict) and data.get("status") in ("active", "completed", "interrupted")}
            # A restart must not erase the requested 72-hour green state.
            # Restore the newest still-visible completion, but mark it read so
            # it does not generate another macOS notification on startup.
            restored: dict[str, tuple[int, str, dict[str, Any]]] = {}
            for data in self.turns.values():
                if data.get("status") != "active":
                    data["announced"] = "1"
            for turn_id, data in self.turns.items():
                completed_at = int(data.get("completed_at") or 0)
                if data.get("status") == "completed" and time.time() - completed_at < COMPLETION_DISPLAY_SECONDS:
                    identity = str(data.get("thread_id") or turn_id)
                    if identity not in restored or completed_at > restored[identity][0]:
                        restored[identity] = (completed_at, turn_id, data)
            for identity, (completed_at, turn_id, data) in restored.items():
                self.recent_completed[identity] = {"turn_id": turn_id, **data}
                self.notice_until = max(self.notice_until, completed_at + COMPLETION_DISPLAY_SECONDS)

    def save(self) -> None:
        write_json_file(TASK_STATE_PATH, {"updatedAt": int(time.time()), "turns": self.turns})

    def update(self) -> tuple[list[dict[str, str]], list[dict[str, str]], str | None]:
        root = Path.home() / ".codex" / "sessions"
        cutoff = time.time() - max(2 * 86400, COMPLETION_DISPLAY_SECONDS)
        changed = False
        for path in root.rglob("*.jsonl"):
            try:
                stat = path.stat()
            except OSError:
                continue
            if stat.st_mtime < cutoff:
                continue
            offset, previous_mtime = self.files.get(path, (0, 0))
            if stat.st_size < offset:
                offset = 0
            if stat.st_size == offset and stat.st_mtime == previous_mtime:
                continue
            with path.open("r", encoding="utf-8", errors="replace") as stream:
                stream.seek(offset)
                while True:
                    line_start = stream.tell()
                    line = stream.readline()
                    if not line:
                        break
                    if not line.endswith('\n'):
                        stream.seek(line_start)
                        break
                    try:
                        event = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if event.get("type") == "response_item":
                        item = event.get("payload") or {}
                        current_turn = self.file_turns.get(path)
                        state = self.turns.get(current_turn, {})
                        call_id = item.get("call_id")
                        if item.get("type") == "message" and item.get("role") == "user":
                            # Async replies arrive as user messages, not as a
                            # second tool result. Any reply resumes this thread.
                            for pending, owner in list(self.pending_confirmations.items()):
                                if self.turns.get(owner, {}).get("rollout_path") == str(path):
                                    self.pending_confirmations.pop(pending, None)
                                    self.async_confirmations.discard(pending)
                        if item.get("type") in ("function_call", "custom_tool_call") and call_id and state.get("status") == "active":
                            name = item.get("name", "").split(".")[-1]
                            arguments = item.get("arguments", item.get("input", ""))
                            # Explicit user-input tools and escalation requests
                            # are observable in rollout records before output.
                            requires_input = name in ("request_user_input", "request_user_input_async")
                            requires_approval = bool(re.search(r'''["']?sandbox_permissions["']?\s*:\s*["']require_escalated["']''', str(arguments)))
                            if requires_input or requires_approval:
                                self.pending_confirmations[call_id] = current_turn
                                if name == "request_user_input_async":
                                    self.async_confirmations.add(call_id)
                        elif item.get("type") in ("function_call_output", "custom_tool_call_output"):
                            try:
                                result = json.loads(item.get("output", ""))
                            except (TypeError, ValueError):
                                result = None
                            # accepted=true only acknowledges that the UI has
                            # shown the question; it is NOT the user's answer.
                            if not (call_id in self.async_confirmations and isinstance(result, dict)
                                    and result.get("accepted") is True):
                                self.pending_confirmations.pop(call_id, None)
                                self.async_confirmations.discard(call_id)
                        continue
                    if event.get("type") != "event_msg":
                        continue
                    payload = event.get("payload") or {}
                    turn_id = payload.get("turn_id")
                    if not turn_id:
                        continue
                    if payload.get("type") == "task_started":
                        for pending, owner in list(self.pending_confirmations.items()):
                            if self.turns.get(owner, {}).get("rollout_path") == str(path):
                                self.pending_confirmations.pop(pending, None)
                                self.async_confirmations.discard(pending)
                        self.file_turns[path] = turn_id
                        match = re.search(r"([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})$", path.stem)
                        next_state = {
                            "status": "active",
                            "thread_id": payload.get("thread_id") or (match.group(1) if match else ""),
                            "rollout_path": str(path),
                            "started_at": int(payload.get("started_at") or time.time()),
                            "last_activity": int(stat.st_mtime),
                        }
                        if self.turns.get(turn_id) != next_state:
                            self.turns[turn_id] = next_state
                            changed = True
                    elif payload.get("type") in ("task_complete", "task_failed", "task_interrupted", "turn_aborted"):
                        # task_complete may carry an API/transport error. It is
                        # terminal, but it is not a successful completion.
                        next_status = "completed" if payload.get("type") == "task_complete" and not payload.get("error") else "interrupted"
                        state = self.turns.setdefault(turn_id, {"thread_id": payload.get("thread_id") or ""})
                        if state.get("status") != next_status:
                            state["status"] = next_status
                            if next_status == "interrupted":
                                for pending, owner in list(self.pending_confirmations.items()):
                                    if owner == turn_id:
                                        self.pending_confirmations.pop(pending, None)
                                        self.async_confirmations.discard(pending)
                                state["completed_at"] = int(payload.get("completed_at") or time.time())
                            if next_status == "completed":
                                completed_at = int(payload.get("completed_at") or time.time())
                                state["completed_at"] = completed_at
                                if time.time() - completed_at < COMPLETION_DISPLAY_SECONDS:
                                    identity = str(state.get("thread_id") or turn_id)
                                    self.recent_completed[identity] = {"turn_id": turn_id, **state}
                            changed = True
                self.files[path] = (stream.tell(), stat.st_mtime)
        now = time.time()
        # A missing terminal record must not leave yesterday's task yellow.
        # Session-file activity is the freshest reliable signal available for
        # an in-progress local turn.
        # A thread's newest turn supersedes unfinished older turns. Otherwise
        # a missing terminal record keeps a finished conversation yellow.
        latest = {}
        for turn_id, data in self.turns.items():
            identity = data.get("thread_id") or turn_id
            if identity not in latest or int(data.get("started_at") or 0) >= int(latest[identity].get("started_at") or 0):
                latest[identity] = dict(turn_id=turn_id, **data)
        for data in latest.values():
            path = Path(data.get("rollout_path") or "")
            if data["status"] == "active" and path in self.files:
                data["last_activity"] = int(self.files[path][1])
        waiting_turns = set(self.pending_confirmations.values())
        for data in latest.values():
            data["waiting"] = data["turn_id"] in waiting_turns
        active = [data for data in latest.values()
                  if data.get("waiting") or (data["status"] == "active" and (
                      RECONNECT_TRACKER.reconnecting.get(data.get("thread_id")) == data["turn_id"] or
                      now - int(data.get("last_activity") or data.get("started_at") or 0) <= ACTIVE_IDLE_SECONDS))]
        completed = None
        if self.ready:
            newly_completed = [data for data in self.turns.values() if data.get("status") == "completed" and not data.get("announced")]
            if newly_completed:
                for data in newly_completed:
                    data["announced"] = "1"
                changed = True
                self.notice = "Task completed"
                self.notice_until = time.time() + COMPLETION_DISPLAY_SECONDS
                # Local macOS notification complements the on-device notice.
                threading.Thread(target=notify_completion, daemon=True).start()
        else:
            for data in self.turns.values():
                if data.get("status") == "completed":
                    data["announced"] = "1"
            self.ready = True
            changed = True
        if changed:
            self.save()
        # Do not let a later completion replace an earlier green task. Expire
        # each thread independently and return newest completions first.
        for identity, item in list(self.recent_completed.items()):
            if now - int(item.get("completed_at") or 0) >= COMPLETION_DISPLAY_SECONDS:
                del self.recent_completed[identity]
        recent_completed = sorted(self.recent_completed.values(),
                                  key=lambda item: int(item.get("completed_at") or 0), reverse=True)
        stopped = [data for data in latest.values() if data["status"] == "interrupted"
                   and now - int(data.get("completed_at") or 0) < INTERRUPTION_DISPLAY_SECONDS]
        stopped_threads = {data.get("thread_id") for data in stopped}
        recent_completed = stopped + [data for data in recent_completed if data.get("thread_id") not in stopped_threads]
        return active, recent_completed, self.notice if time.time() < self.notice_until else None


def notify_completion() -> None:
    try:
        subprocess.run(["osascript", "-e", 'display notification "Task completed" with title "Codex"'],
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       timeout=3, check=False)
    except (OSError, subprocess.TimeoutExpired):
        pass


TRACKER = TaskTracker()


def local_goal_summary() -> tuple[int, str | None]:
    """Supplement history with the GUI's durable task/goals state, if present."""
    database = Path.home() / ".codex" / "goals_1.sqlite"
    if not database.exists():
        return 0, None
    try:
        uri = f"file:{database}?mode=ro"
        with sqlite3.connect(uri, uri=True) as db:
            active = db.execute("SELECT count(*) FROM thread_goals WHERE status='active'").fetchone()[0]
            row = db.execute("SELECT objective FROM thread_goals WHERE status='active' ORDER BY updated_at_ms DESC LIMIT 1").fetchone()
            return active, row[0] if row else None
    except sqlite3.Error:
        return 0, None


def local_thread_details(thread_id: str) -> tuple[str | None, int, str]:
    if not thread_id:
        return None, 0, ""
    database = Path.home() / ".codex" / "state_5.sqlite"
    try:
        with sqlite3.connect(f"file:{database}?mode=ro", uri=True) as db:
            row = db.execute("SELECT COALESCE(name, title, preview), tokens_used, cwd FROM threads WHERE id=?", (thread_id,)).fetchone()
            return (row[0] if row and row[0] else None, int(row[1] or 0) if row else 0, row[2] if row else "")
    except sqlite3.Error:
        return None, 0, ""


def live_task_status() -> dict[str, Any]:
    """Build task state solely from local lifecycle events and thread metadata."""
    RECONNECT_TRACKER.update()
    cli_active, just_completed, completion = TRACKER.update()
    task_items = []
    seen_threads = set()
    task_index_by_thread: dict[str, int] = {}
    task_index_by_identity: dict[tuple[str, str], int] = {}
    task_activity: list[int] = []
    for item in cli_active:
        thread_id = item.get("thread_id", "")
        if task_hidden(item):
            continue
        if not thread_id or thread_id in seen_threads:
            continue
        seen_threads.add(thread_id)
        title, tokens, cwd = local_thread_details(thread_id)
        name = title or "Codex task"
        identity = (name, cwd)
        activity = int(item.get("last_activity") or item.get("started_at") or 0)
        if identity in task_index_by_identity:
            index = task_index_by_identity[identity]
            # Codex can create a continuation thread for the same workspace
            # task. Keep its newer/higher-token record as one dashboard task.
            if activity >= task_activity[index] or tokens > task_items[index]["tokens"]:
                task_items[index]["tokens"] = tokens
                task_items[index]["id"] = item["turn_id"]
                task_activity[index] = activity
            task_index_by_thread[thread_id] = index
            continue
        reconnecting = RECONNECT_TRACKER.reconnecting.get(thread_id) == item.get("turn_id")
        task_items.append({"id": item["turn_id"], "name": name, "tokens": tokens,
                           "status": "WAITING" if item.get("waiting") else "RECONNECTING" if reconnecting else "ACTIVE"})
        index = len(task_items) - 1
        task_index_by_thread[thread_id] = index
        task_index_by_identity[identity] = index
        task_activity.append(activity)
    active_count = len(task_items)
    for item in just_completed:
        if task_hidden(item):
            continue
        thread_id = item.get("thread_id", "")
        if thread_id in seen_threads:
            # Current activity takes precedence over a previous completion.
            continue
        if len(task_items) >= 4:
            break
        title, tokens, _ = local_thread_details(thread_id)
        task_items.append({"id": item["turn_id"], "name": title or "Codex task", "tokens": tokens,
                           "status": "INTERRUPTED" if item.get("status") == "interrupted" else "COMPLETED"})
    task_items = task_items[:4]
    return {"active": active_count, "recent": 0,
            "headline": task_items[0]["name"] if task_items else "No active task",
            "items": task_items, "event": completion or ""}


def refresh_account_cache() -> None:
    """Refresh slow App Server fields without blocking local task updates."""
    try:
        limits = CLIENT.request("account/rateLimits/read")
        usage = CLIENT.request("account/usage/read")
        account = CLIENT.request("account/read", {"refreshToken": False})
        buckets = limits.get("rateLimitsByLimitId") or {}
        main = buckets.get("codex") or limits.get("rateLimits") or {}
        other = next((v for k, v in buckets.items() if k != "codex"), {})
        daily = usage.get("dailyUsageBuckets") or []
        today = time.strftime("%Y-%m-%d")
        today_tokens = next((b.get("tokens", 0) for b in daily if b.get("startDate") == today), 0)
        data = {
            "plan": account.get("account", {}).get("planType") or "API key",
            "quota": {"primary": main.get("primary") or {}, "secondary": other.get("primary") or {}},
            "resetCredits": (limits.get("rateLimitResetCredits") or {}).get("availableCount", 0),
            "quotaUpdatedAt": int(time.time()),
            "usage": {"todayTokens": today_tokens, "lifetimeTokens": (usage.get("summary") or {}).get("lifetimeTokens", 0),
                      "peakDailyTokens": (usage.get("summary") or {}).get("peakDailyTokens", 0)},
            "tasks": {}, "updatedAt": int(time.time()),
        }
        with CACHE_LOCK:
            CACHE.update(at=time.time(), data=data, error="", refreshing=False)
        write_json_file(STATUS_CACHE_PATH, data)
    except Exception as exc:
        with CACHE_LOCK:
            CACHE.update(error=str(exc), refreshing=False)


def current_status() -> dict[str, Any]:
    # The BLE publisher must never wait on an App Server RPC: it would turn a
    # transient account timeout into a frozen task display.
    with TASK_LOCK:
        tasks = live_task_status()
    with CACHE_LOCK:
        stale = not CACHE["data"] or time.time() - CACHE["at"] >= ACCOUNT_CACHE_SECONDS
        if stale and not CACHE["refreshing"]:
            CACHE["refreshing"] = True
            threading.Thread(target=refresh_account_cache, name="codex-tip-account-refresh", daemon=True).start()
        data = json.loads(json.dumps(CACHE["data"])) if CACHE["data"] else {
            "plan": "Loading…", "quota": {"primary": {}, "secondary": {}}, "resetCredits": 0,
            "usage": {"todayTokens": 0, "lifetimeTokens": 0},
        }
        error = CACHE["error"]
    data["tasks"] = tasks
    data["updatedAt"] = int(time.time())
    if error:
        data["error"] = error
    else:
        data.pop("error", None)
    return data


def ble_frame(status: dict[str, Any]) -> bytes:
    """Credential-free, compact status frame for a single BLE GATT write."""
    quota = status.get("quota", {})
    primary, secondary = quota.get("primary", {}), quota.get("secondary", {})
    usage, tasks = status.get("usage", {}), status.get("tasks", {})
    def clean(value: Any, limit: int = 54) -> str:
        return str(value or "").replace(";", ",").replace("=", ":").replace("\n", " ")[:limit]
    def remaining_minutes(epoch: Any) -> int:
        try:
            return max(0, int((int(epoch) - time.time()) / 60))
        except (TypeError, ValueError):
            return -1
    quota_stale = time.time() - int(status.get("quotaUpdatedAt") or 0) > 90
    fields = {
        "PL": clean(status.get("plan"), 14), "P": primary.get("usedPercent", -1),
        "S": secondary.get("usedPercent", -1), "PR": primary.get("resetsAt", 0),
        "SR": secondary.get("resetsAt", 0), "C": status.get("resetCredits", 0),
        "PM": remaining_minutes(primary.get("resetsAt")), "SM": remaining_minutes(secondary.get("resetsAt")),
        "D": usage.get("todayTokens", 0), "L": usage.get("lifetimeTokens", 0), "M": usage.get("peakDailyTokens", 0),
        "A": tasks.get("active", 0), "B": len(tasks.get("items", [])), "R": tasks.get("recent", 0),
        "Q": int(quota_stale),
        "T": clean(tasks.get("headline")), "E": clean(tasks.get("event"), 42),
    }
    # Keep last-known percentages visible; Q explicitly marks stale data.
    return ";".join(f"{key}={value}" for key, value in fields.items()).encode()


def ble_task_frames(status: dict[str, Any]) -> list[bytes]:
    """One compact GATT frame per task keeps each BLE write below the MTU."""
    tasks = status.get("tasks", {}).get("items", [])[:4]
    frames = []
    for index, task in enumerate(tasks):
        # The device wraps this into two lines. Keep enough context for a
        # meaningful task label while each write remains safely below MTU.
        name = str(task.get("name") or "Task").replace(";", ",").replace("=", ":").replace("\n", " ")[:18]
        state = {"COMPLETED": "DONE", "WAITING": "WAIT", "RECONNECTING": "WAIT", "INTERRUPTED": "STOP"}.get(task.get("status"), "RUN")
        frames.append(f"I={index};K={task.get('id', '')};N={name};V={int(task.get('tokens') or 0)};X={state}".encode())
    return frames


async def ble_loop() -> None:
    if BleakScanner is None:
        print("BLE disabled: install bleak to enable it", flush=True)
        return
    while True:
        try:
            device = await BleakScanner.find_device_by_filter(
                lambda d, ad: d.name == "CODEX-TIP" or BLE_SERVICE_UUID.lower() in
                {str(uuid).lower() for uuid in (ad.service_uuids or [])}, timeout=8.0)
            if device is None:
                await asyncio.sleep(3)
                continue
            async with BleakClient(device) as client:
                print(f"BLE connected: {device.address}", flush=True)
                if client.services.get_characteristic(BLE_ACTION_UUID):
                    await client.start_notify(BLE_ACTION_UUID, handle_device_action)
                    print("BLE task actions subscribed", flush=True)
                while client.is_connected:
                    status = current_status()
                    await client.write_gatt_char(BLE_STATUS_UUID, ble_frame(status), response=False)
                    for frame in ble_task_frames(status):
                        await client.write_gatt_char(BLE_STATUS_UUID, frame, response=False)
                    # current_status refreshes local task events every time;
                    # account RPC fields remain cached independently.
                    await asyncio.sleep(LIVE_PUSH_SECONDS)
        except Exception as exc:
            print(f"BLE reconnecting: {exc}", flush=True)
            await asyncio.sleep(3)


def start_ble_publisher() -> None:
    thread = threading.Thread(target=lambda: asyncio.run(ble_loop()), name="codex-tip-ble", daemon=True)
    thread.start()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path not in ("/", "/status"):
            self.send_error(404)
            return
        payload = json.dumps(current_status(), separators=(",", ":")).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *_: Any) -> None:
        pass


def main() -> None:
    parser = argparse.ArgumentParser(description="Read-only Codex dashboard bridge for M5Stack")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", default=8765, type=int)
    parser.add_argument("--ble", action="store_true", help="push status to a nearby CODEX-TIP over BLE")
    args = parser.parse_args()
    if args.ble:
        start_ble_publisher()
    print(f"Codex Tip bridge: http://{args.host}:{args.port}/status")
    ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
