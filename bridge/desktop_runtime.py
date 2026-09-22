"""Desktop settings and agent boundary, independent of Cocoa and BLE."""
from __future__ import annotations

import json
import os
import secrets
import re
import threading
from pathlib import Path
from typing import Protocol, Any

APP_DIR = Path.home() / "Library/Application Support/Agent Display"
DEFAULTS = {"agent": "codex", "bleEnabled": True, "completionHours": 48,
            "pushInterval": 0.25, "accountInterval": 2.0}


class AgentProvider(Protocol):
    id: str
    name: str
    def status(self) -> dict[str, Any]: ...
    def hide(self, task_id: str) -> None: ...
    def restore_hidden(self) -> None: ...


class DesktopRuntime:
    def __init__(self, directory: Path = APP_DIR):
        self.directory = directory
        directory.mkdir(parents=True, exist_ok=True)
        self.path = directory / "settings.json"
        self.lock = threading.RLock()
        self.settings = dict(DEFAULTS)
        try:
            self.settings.update(self.validate(json.loads(self.path.read_text())))
        except (OSError, ValueError, TypeError):
            pass
        token_path = directory / "control-token"
        try:
            self.token = token_path.read_text().strip()
        except FileNotFoundError:
            self.token = secrets.token_hex(32)
            fd = os.open(token_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w") as stream:
                stream.write(self.token)
        self.providers: dict[str, AgentProvider] = {}
        self.device = {"state": "starting", "address": "", "error": ""}

    @staticmethod
    def validate(values):
        if not isinstance(values, dict) or set(values) - set(DEFAULTS):
            raise ValueError("Unknown setting")
        if "agent" in values and (not isinstance(values["agent"], str) or not re.fullmatch(r"[a-z][a-z0-9_-]{0,31}", values["agent"])):
            raise ValueError("Invalid agent identifier")
        if "bleEnabled" in values and not isinstance(values["bleEnabled"], bool):
            raise ValueError("bleEnabled must be boolean")
        for key, lo, hi in [("completionHours", 1, 168), ("pushInterval", .1, 10), ("accountInterval", 2, 300)]:
            if key in values and (type(values[key]) not in (int, float) or not lo <= values[key] <= hi):
                raise ValueError(f"{key} must be between {lo} and {hi}")
        return values

    def update(self, values):
        self.validate(values)
        with self.lock:
            if "agent" in values and values["agent"] not in self.providers:
                raise ValueError("Agent is not installed")
            updated = {**self.settings, **values}
            temporary = self.path.with_suffix(".tmp")
            temporary.write_text(json.dumps(updated))
            os.replace(temporary, self.path)
            self.settings = updated
            return dict(updated)

    def provider(self) -> AgentProvider:
        return self.providers[self.settings["agent"]]

    def snapshot(self):
        with self.lock:
            return {"settings": dict(self.settings), "device": dict(self.device),
                    "agents": [{"id": p.id, "name": p.name, "available": True} for p in self.providers.values()],
                    "version": 1}

    def set_device(self, state, address="", error=""):
        with self.lock:
            self.device = {"state": state, "address": address, "error": error}
