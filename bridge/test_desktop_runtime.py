import json
import tempfile
import threading
import unittest
import urllib.request
import urllib.error
from pathlib import Path
from unittest.mock import patch
from http.server import ThreadingHTTPServer

from desktop_runtime import DesktopRuntime
import codex_tip_bridge as bridge


class FakeProvider:
    id = "codex"
    name = "Codex"
    hidden = None
    restored = False
    def status(self): return {"tasks": {"items": []}}
    def hide(self, task_id): self.hidden = task_id
    def restore_hidden(self): self.restored = True


class DesktopTests(unittest.TestCase):
    def test_registered_agent_can_be_selected(self):
        with tempfile.TemporaryDirectory() as directory:
            runtime = DesktopRuntime(Path(directory))
            provider = FakeProvider()
            provider.id = "test-agent"
            runtime.providers[provider.id] = provider
            runtime.update({"agent": provider.id})
            self.assertIs(runtime.provider(), provider)
            self.assertEqual(runtime.snapshot()["agents"][0]["id"], "test-agent")

    def test_settings_persist_and_reject_invalid(self):
        with tempfile.TemporaryDirectory() as directory:
            runtime = DesktopRuntime(Path(directory))
            runtime.update({"completionHours": 48, "bleEnabled": False})
            restored = DesktopRuntime(Path(directory))
            self.assertEqual(restored.settings["completionHours"], 48)
            self.assertFalse(restored.settings["bleEnabled"])
            self.assertEqual(runtime.token, restored.token)
            for values in ({"completionHours": 0}, {"pushInterval": float("nan")},
                           {"bleEnabled": "yes"}, {"agent": "opencode"}, {"other": 5}):
                with self.assertRaises(ValueError): runtime.update(values)
            self.assertEqual(runtime.settings, restored.settings)

    def test_private_controls_and_legacy_status(self):
        with tempfile.TemporaryDirectory() as directory:
            runtime = DesktopRuntime(Path(directory))
            provider = FakeProvider()
            runtime.providers[provider.id] = provider
            with patch.object(bridge, "RUNTIME", runtime):
                server = ThreadingHTTPServer(("127.0.0.1", 0), bridge.Handler)
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                base = f"http://127.0.0.1:{server.server_port}"
                def request(path, body=None, token=True):
                    headers = {"Authorization": "Bearer " + runtime.token} if token else {}
                    data = None if body is None else json.dumps(body).encode()
                    with urllib.request.urlopen(urllib.request.Request(base + path, data=data, headers=headers)) as response:
                        return json.load(response)
                try:
                    self.assertIn("tasks", request("/status", token=False))
                    with self.assertRaises(urllib.error.HTTPError) as error:
                        request("/api/tasks/hide", {"id": "t"}, token=False)
                    self.assertEqual(error.exception.code, 403)
                    error.exception.close()
                    request("/api/tasks/hide", {"id": "t"})
                    self.assertEqual(provider.hidden, "t")
                    request("/api/tasks/restore", {})
                    self.assertTrue(provider.restored)
                    self.assertEqual(request("/api/desktop")["agents"][0]["id"], "codex")
                    with self.assertRaises(urllib.error.HTTPError) as error:
                        request("/api/settings", {"completionHours": -1})
                    self.assertEqual(error.exception.code, 400)
                    error.exception.close()
                finally:
                    server.shutdown()
                    server.server_close()
                    thread.join()


if __name__ == "__main__": unittest.main()
