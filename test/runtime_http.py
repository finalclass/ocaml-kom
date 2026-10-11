"""Real native plugins, daemon lifecycle, files, cutover and crash journal."""
import concurrent.futures
import http.client
import json
import os
from pathlib import Path
import shutil
import socket
import sqlite3
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / "_build/default/bin/main.exe"
PLUGINS = ROOT / "_build/default/test/plugins"


def main():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    with tempfile.TemporaryDirectory(prefix="kom-runtime-test-") as temporary:
        temporary = Path(temporary)
        directory = temporary / "runtime"
        cleanup = temporary / "cleanup"
        env = dict(os.environ, KOM_TEST_CLEANUP=str(cleanup))

        def cli(*args, ok=True):
            result = subprocess.run([str(BINARY), "--directory", str(directory), *map(str, args)],
                                    env=env, capture_output=True, text=True, timeout=20)
            assert (result.returncode == 0) == ok, (args, result.stdout, result.stderr)
            return result.stdout

        def command(*args):
            return json.loads(cli(*args))

        def plugin(version):
            return PLUGINS / version / f"fixture_{version}.cmxs"

        def call(flow, message=None):
            return command("call", "fixture", flow, json.dumps(message or {}))

        def request(method, path, body=None):
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=15)
            try:
                connection.request(method, path, body, {"Content-Type": "application/json"})
                response = connection.getresponse()
                return response.status, dict(response.getheaders()), response.read()
            finally:
                connection.close()

        def rpc(app, flow, params=None):
            status, _, body = request("POST", f"/apps/{app}/rpc", json.dumps(
                {"jsonrpc": "2.0", "id": 1, "method": flow, "params": params or {}}))
            assert status == 200
            return json.loads(body)

        def wait(condition):
            deadline = time.monotonic() + 10
            while not condition():
                assert time.monotonic() < deadline, "Timed out"
                time.sleep(0.01)

        def fixture_status():
            return next(app for app in command("apps")["apps"] if app["id"] == "fixture")

        running = False
        try:
            cli("start", "--port", port, "--workers", 2)
            running = True
            pid = command("apps")["pid"]
            assert (directory / "control.sock").stat().st_mode & 0o777 == 0o600
            cli("serve", "--port", port, ok=False)
            assert command("add", "plugin", plugin("v1")) == "fixture"
            call("legacy")  # This flow disappears in v2; completed requests remain valid.
            assert call("increment")["n"] == 1
            assert call("read")["keys"] == [101]
            source = temporary / "binary"
            source.write_bytes(b"\x00\xff\r\nfile")
            command("put", "fixture", "nested/file.bin", source)
            assert command("files", "fixture") == ["nested/file.bin"]
            status, headers, body = request("GET", "/apps/fixture/files/nested/file.bin")
            assert status == 200 and body == source.read_bytes()
            assert headers["X-Content-Type-Options"] == "nosniff"
            for path in ["../escape", "/absolute", "a/../escape", "a//escape"]:
                cli("put", "fixture", path, source, ok=False)
            assert request("GET", "/apps/fixture/files/%2e%2e/plugins.json")[0] == 400
            link = directory / "apps/fixture/files/link"
            link.symlink_to(source)
            assert request("GET", "/apps/fixture/files/link")[0] == 400
            link.unlink()
            assert request("GET", "/apps/fixture/files/nested")[0] == 400
            command("put", "fixture", "plus+and&.bin", source)
            assert request("GET", "/apps/fixture/files/plus+and&.bin")[2] == source.read_bytes()
            command("delete", "fixture", "plus+and&.bin")
            outside = temporary / "outside"
            (outside / "files").mkdir(parents=True)
            application_link = directory / "apps/todo"
            application_link.symlink_to(outside, target_is_directory=True)
            cli("add", "plugin", ROOT / "_build/default/examples/todo.cmxs", ok=False)
            application_link.unlink()
            command("add", "plugin", ROOT / "_build/default/examples/todo.cmxs")
            assert command("files", "todo") == []
            for name in ["index.html", "task.html", "app.js"]:
                command("put", "todo", name, ROOT / "examples" / name)
            status, _, body = request("GET", "/apps/todo/")
            assert status == 200 and b'action="/apps/todo/add_task"' in body
            assert b'src="/apps/todo/app.js"' in body
            entered, release = temporary / "entered", temporary / "release"
            with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
                holding = pool.submit(rpc, "fixture", "hold", {"entered": str(entered), "release": str(release)})
                wait(entered.exists)
                replacing = pool.submit(command, "add", "plugin", plugin("v2"))
                wait(lambda: fixture_status()["paused"])
                queued = pool.submit(rpc, "fixture", "increment")
                time.sleep(0.1)
                assert not replacing.done() and not queued.done()
                assert not cleanup.exists(), "Cleanup ran before the old operation drained"
                assert rpc("todo", "list_tasks")["result"] == {"tasks": []}
                release.touch()
                assert holding.result().get("result", {}).get("generation") == 1, holding.result()
                assert replacing.result() == "fixture"
                assert queued.result()["result"] == {"n": 11, "generation": 2}
            assert cleanup.read_text().splitlines() == ["1"]
            assert call("read")["keys"] == [211]  # Eager rebuild of the versioned view.
            assert command("apps")["pid"] == pid
            cli("add", "plugin", plugin("incompatible"), ok=False)
            assert call("read")["generation"] == 2
            cli("add", "plugin", plugin("empty"), ok=False)
            cli("add", "plugin", plugin("broken"), ok=False)
            assert "4" in cleanup.read_text().splitlines()
            assert "error" in rpc("fixture", "fail")
            assert call("read")["n"] == 11
            command("add", "plugin", plugin("v2"))  # The same unit and source file can reload again.
            assert call("read")["n"] == 11
            cli("restart")
            assert command("apps")["pid"] != pid
            assert call("read")["n"] == 11
            assert request("GET", "/apps/fixture/files/nested/file.bin")[2] == source.read_bytes()
            entered, release = temporary / "stop-entered", temporary / "stop-release"
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                holding = pool.submit(rpc, "fixture", "hold", {"entered": str(entered), "release": str(release)})
                wait(entered.exists)
                stopping = pool.submit(cli, "stop")
                time.sleep(0.1)
                assert not stopping.done(), "stop returned before accepted HTTP work completed"
                release.touch()
                assert holding.result()["result"]["generation"] == 2
                stopping.result()
            running = False

            # Crash before commit: pending points at a distinct artifact; DB still owns current.
            manifest = directory / "plugins.json"
            entries = json.loads(manifest.read_text())
            entry = next(e for e in entries if e["id"] == "fixture")
            old = entry["current"]
            pending = "pending-before.cmxs"
            shutil.copyfile(plugin("v2"), directory / "plugins" / pending)
            entry["pending"] = pending
            manifest.write_text(json.dumps(entries))
            cli("start")
            running = True
            assert fixture_status()["plugin"] == old
            assert not (directory / "plugins" / pending).exists()
            cli("stop")
            running = False

            # Crash after commit, before manifest finalization: committed generation wins.
            entries = json.loads(manifest.read_text())
            entry = next(e for e in entries if e["id"] == "fixture")
            pending = "pending-after.cmxs"
            shutil.copyfile(plugin("v2"), directory / "plugins" / pending)
            entry["pending"] = pending
            manifest.write_text(json.dumps(entries))
            with sqlite3.connect(directory / "data.sqlite") as database:
                database.execute("UPDATE kom_kv SET value=? WHERE system='fixture' AND key='runtime/plugin'", (pending,))
            cli("start")
            running = True
            assert fixture_status()["plugin"] == pending
            assert call("read")["n"] == 11
            assert not (directory / "plugins" / old).exists()
            command("delete", "fixture", "nested/file.bin")
            assert request("GET", "/apps/fixture/files/nested/file.bin")[0] == 404
            command("remove", "fixture")
            assert all(app["id"] != "fixture" for app in command("apps")["apps"])
            cli("restart")
            assert [app["id"] for app in command("apps")["apps"]] == ["todo"]
            command("add", "plugin", plugin("v2"))
            assert call("read")["n"] == 11  # Removal retains private persistent data.
            cli("stop")
            running = False
            entries = [e for e in json.loads(manifest.read_text()) if e["id"] != "fixture"]
            pending = "first-install.cmxs"
            shutil.copyfile(plugin("v1"), directory / "plugins" / pending)
            entries.append({"id": "fixture", "current": None, "pending": pending})
            manifest.write_text(json.dumps(entries))
            with sqlite3.connect(directory / "data.sqlite") as database:
                database.execute("DELETE FROM kom_kv WHERE system='fixture'")
            cli("start")
            running = True
            assert [app["id"] for app in command("apps")["apps"]] == ["todo"]
            assert not (directory / "plugins" / pending).exists()
        except BaseException:
            if (directory / "runtime.log").exists():
                print((directory / "runtime.log").read_text())
            raise
        finally:
            if running:
                cli("stop")
    print("PASS native plugins, buffering, cleanup, isolation, files, daemon/restart and cutover journal")


if __name__ == "__main__":
    main()
