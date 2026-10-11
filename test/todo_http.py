import http.client
import json
from pathlib import Path
import socket
import subprocess
import tempfile
import time
from urllib.parse import urlencode

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / "_build/default/examples/main.exe"


def request(port, method, path, body=None, content_type=None):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    headers = {"Content-Type": content_type} if content_type else {}
    try:
        connection.request(method, path, body, headers)
        response = connection.getresponse()
        return response.status, dict(response.getheaders()), response.read().decode()
    finally:
        connection.close()


def start(port, database, log):
    process = subprocess.Popen(
        [str(BINARY), "--port", str(port), "--db", str(database)],
        cwd=ROOT, stdout=log, stderr=log,
    )
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise AssertionError(f"Server exited: {process.returncode}")
        try:
            if request(port, "GET", "/")[0] == 200:
                return process
        except (OSError, http.client.HTTPException):
            pass
        time.sleep(0.02)
    process.kill()
    process.wait()
    raise AssertionError("Server did not start")


def stop(process):
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
        raise AssertionError("Server did not close on SIGTERM")
    assert process.returncode == 0, process.returncode


def main():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    with tempfile.TemporaryDirectory(prefix="kom-http-") as directory:
        database = Path(directory) / "todo.sqlite"
        with tempfile.TemporaryFile(mode="w+") as log:
            process = start(port, database, log)
            try:
                def raw(value):
                    status, _, body = request(port, "POST", "/rpc", json.dumps(value), "application/json")
                    return status, json.loads(body) if body else None

                def rpc(method, params=None):
                    status, response = raw({"jsonrpc": "2.0", "id": "test", "method": method, "params": params or {}})
                    assert status == 200
                    assert response["id"] == "test"
                    return response

                assert rpc("list_tasks")["result"] == {"tasks": []}
                assert rpc("add_task", {"name": " "})["error"]["code"] == -32602
                assert rpc("add_task", {"name": 3})["error"]["code"] == -32602
                assert rpc("list_tasks", ["invalid"])["error"]["code"] == -32602
                assert rpc("add_task", {"other": "missing name"})["error"]["code"] == -32602
                assert raw({"jsonrpc": "2.0", "id": 1, "method": "add_task", "params": None})[1]["error"]["code"] == -32602
                assert raw({"jsonrpc": "2.0", "id": 1})[1]["error"]["code"] == -32600
                assert raw({"id": 1, "method": "list_tasks"})[1]["error"]["code"] == -32600
                assert raw({"jsonrpc": "2.0", "id": float("nan"), "method": "add_task", "params": {"name": "invalid ID"}})[1]["error"]["code"] == -32600
                assert rpc("add_task", {"name": "invalid number", "extra": float("inf")})["error"]["code"] == -32602
                for body, code in [
                    ('{"jsonrpc":"2.0","id":1,"method":"add_task","method":"remove_task","params":{"name":"duplicate method"}}', -32600),
                    ('{"jsonrpc":"2.0","id":1,"method":"add_task","params":{"name":"a","name":"b"}}', -32602),
                    ('{"jsonrpc":"2.0","id":1,"method":"add_task","params":{"name":"nested","extra":{"a":1,"a":2}}}', -32602),
                ]:
                    status, _, response = request(port, "POST", "/rpc", body, "application/json")
                    assert status == 200 and json.loads(response)["error"]["code"] == code
                assert rpc("list_tasks")["result"] == {"tasks": []}
                name = '<script>alert("x")</script> & zadanie'
                task = rpc("add_task", {"name": name})["result"]
                task_id = task["task_id"]
                assert task_id == "1"
                assert rpc("read_task", {"task_id": task_id})["result"]["name"] == name
                status, _, html = request(port, "GET", "/")
                assert status == 200 and 'data-rpc="add_task"' in html and 'data-rpc="remove_task"' in html
                assert name not in html and "&lt;script&gt;" in html and "&amp; zadanie" in html
                assert f'href="/tasks/{task_id}"' in html
                status, _, detail = request(port, "GET", f"/tasks/{task_id}")
                assert status == 200 and "&lt;script&gt;" in detail and 'href="/"' in detail
                assert rpc("unknown")["error"]["code"] == -32601
                assert raw({"jsonrpc": "1.0", "id": 1, "method": "list_tasks"})[1]["error"]["code"] == -32600
                assert raw([])[1]["error"]["code"] == -32600
                assert raw(4)[1]["error"]["code"] == -32600
                assert raw({"jsonrpc": "2.0", "id": {}, "method": "list_tasks"})[1]["error"]["code"] == -32600
                batch = raw([{"jsonrpc": "2.0", "id": 1, "method": "list_tasks"}, {"jsonrpc": "2.0", "method": "list_tasks"}, 4])[1]
                assert len(batch) == 2 and batch[0]["id"] == 1 and batch[1]["error"]["code"] == -32600
                assert raw({"jsonrpc": "2.0", "method": "list_tasks"}) == (204, None)
                assert raw([{"jsonrpc": "2.0", "method": "list_tasks"}]) == (204, None)
                status, _, response = request(port, "POST", "/rpc", "{", "application/json")
                assert status == 200 and json.loads(response)["error"]["code"] == -32700
                assert request(port, "POST", "/rpc", "{}", "text/plain")[0] == 415
                assert request(port, "GET", "/missing")[0] == 404
                assert request(port, "GET", "/tasks/missing")[0] == 404
                catalog = rpc("kom.catalog")["result"]
                assert len(catalog["cell_kinds"]) == 2 and len(catalog["flows"]) == 7
                assert '"impl"' not in json.dumps(catalog)
                stop(process)
                process = start(port, database, log)
                assert rpc("list_tasks")["result"]["tasks"] == [task]
                task = rpc("update_task", {"task_id": task_id, "done": True, "priority": 5})["result"]
                assert rpc("list_finished_tasks", {"min_priority": 5, "max_priority": 5})["result"]["tasks"] == [task]
                assert rpc("list_finished_tasks", {"min_priority": 6})["result"]["tasks"] == []
                assert "checked" in request(port, "GET", f"/tasks/{task_id}")[2]
                assert "Ukończone" in request(port, "GET", "/?finished=1&min_priority=5")[2]
                next_task = rpc("add_task", {"name": "persistent counter"})["result"]
                assert next_task["task_id"] == "2"
                page = rpc("list_tasks", {"limit": 1})["result"]
                assert [t["task_id"] for t in page["tasks"]] == ["1"]
                assert rpc("list_tasks", {"limit": 1, "cursor": page["cursor"]})["result"]["tasks"][0]["task_id"] == "2"
                assert "Następna strona" in request(port, "GET", "/?limit=1")[2]
                assert rpc("list_finished_tasks", {"cursor": page["cursor"]})["error"]["code"] == -32000
                assert rpc("remove_task", {"task_id": task_id})["result"]["task_id"] == task_id
                assert rpc("read_task", {"task_id": task_id})["error"]["code"] == -32004
                status, headers, _ = request(port, "POST", "/add_task", urlencode({"name": "fallback żółć"}), "application/x-www-form-urlencoded")
                assert status == 303 and headers["Location"] == "/"
                tasks = rpc("list_tasks")["result"]["tasks"]
                assert [item["task_id"] for item in tasks] == ["2", "3"]
                assert tasks[-1]["name"] == "fallback żółć"
                status, headers, _ = request(port, "POST", "/remove_task", "task_id=3", "application/x-www-form-urlencoded")
                assert status == 303 and headers["Location"] == "/"
                status, _, _ = request(port, "POST", "/update_task", "task_id=2&priority=9&done=true", "application/x-www-form-urlencoded")
                assert status == 303
                assert rpc("list_finished_tasks", {"min_priority": 9})["result"]["tasks"][0]["task_id"] == "2"
                status, _, _ = request(port, "POST", "/update_task", "task_id=2&priority=1", "application/x-www-form-urlencoded")
                assert status == 303 and rpc("list_finished_tasks")["result"]["tasks"] == []
                assert len(rpc("list_tasks")["result"]["tasks"]) == 1
            except BaseException:
                log.seek(0)
                print(log.read())
                raise
            finally:
                if process.poll() is None:
                    stop(process)
    print("PASS Todo HTTP, JSON-RPC, SSR/forms, escaping and restart")


if __name__ == "__main__":
    main()
