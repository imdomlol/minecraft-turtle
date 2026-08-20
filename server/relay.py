#!/usr/bin/env python3
"""
relay.py -- HTTP command relay between an operator and ComputerCraft turtles.

Turtles poll  POST /poll {id, label}                for a queued command
Turtles post  POST /result {id, cmd_id, ok, output}  when a command finishes
Turtles post  POST /log {id, text}                   append to the live console feed

Operators (via turtlectl.py or curl) use:
  POST /cmd?id=<id>   {command}   queue a command for one turtle
  POST /cmd_all       {command}   queue a command for every known turtle
  GET  /status                    list turtles and when they last checked in
  GET  /results?id=<id>           recent results for one turtle
  GET  /log?id=<id>&after=<n>     live console feed since offset n

Every request must include:  Authorization: Bearer <token>
Set the shared secret via the RELAY_TOKEN environment variable before
starting the server -- pick something random, don't reuse a real password,
and never commit it (this repo is public).

State (registry / queue / recent results) is persisted to relay_state.json
next to this script so a restart doesn't drop queued work.
"""
import hmac
import json
import os
import secrets
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = os.environ.get("RELAY_TOKEN")
if not TOKEN:
    raise SystemExit("Set RELAY_TOKEN to a shared secret before starting the relay.")

STATE_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "relay_state.json")
MAX_RESULTS_PER_TURTLE = 50
MAX_LOG_CHARS = 20000  # per turtle; logs are in-memory only, not persisted

lock = threading.Lock()
state = {"turtles": {}, "queue": {}, "results": {}}
logs = {}  # tid -> {"text": str, "base": int}  (base = chars trimmed off the front)


def load_state():
    global state
    if os.path.exists(STATE_PATH):
        with open(STATE_PATH) as f:
            state = json.load(f)
    state.setdefault("turtles", {})
    state.setdefault("queue", {})
    state.setdefault("results", {})


def save_state():
    tmp = STATE_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f)
    os.replace(tmp, STATE_PATH)


def next_cmd_id():
    return secrets.token_hex(4)


class Handler(BaseHTTPRequestHandler):
    server_version = "TurtleRelay/1.0"

    def _authed(self):
        auth = self.headers.get("Authorization", "")
        expected = f"Bearer {TOKEN}"
        return hmac.compare_digest(auth, expected)

    def _send_json(self, code, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        if length == 0:
            return {}
        raw = self.rfile.read(length)
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            return None

    def _params(self, query):
        out = {}
        for pair in query.split("&"):
            if "=" in pair:
                k, v = pair.split("=", 1)
                out[k] = v
        return out

    def log_message(self, fmt, *args):
        pass

    def do_POST(self):
        if not self._authed():
            return self._send_json(401, {"error": "unauthorized"})

        path, _, query = self.path.partition("?")
        params = self._params(query)
        body = self._read_json()
        if body is None:
            return self._send_json(400, {"error": "bad json"})

        if path == "/poll":
            return self._handle_poll(body)
        if path == "/result":
            return self._handle_result(body)
        if path == "/log":
            return self._handle_log_post(body)
        if path == "/cmd":
            return self._handle_cmd(params.get("id"), body)
        if path == "/cmd_all":
            return self._handle_cmd_all(body)
        return self._send_json(404, {"error": "not found"})

    def do_GET(self):
        if not self._authed():
            return self._send_json(401, {"error": "unauthorized"})
        path, _, query = self.path.partition("?")
        params = self._params(query)
        if path == "/status":
            return self._handle_status()
        if path == "/results":
            return self._handle_results(params.get("id"))
        if path == "/log":
            return self._handle_log_get(params.get("id"), params.get("after"))
        return self._send_json(404, {"error": "not found"})

    def _handle_poll(self, body):
        tid = str(body.get("id") or "")
        if not tid:
            return self._send_json(400, {"error": "missing id"})
        with lock:
            state["turtles"][tid] = {
                "label": body.get("label"),
                "last_seen": time.time(),
            }
            queue = state["queue"].get(tid) or []
            cmd = queue.pop(0) if queue else None
            state["queue"][tid] = queue
            save_state()
        return self._send_json(200, cmd or {})

    def _handle_result(self, body):
        tid = str(body.get("id") or "")
        if not tid:
            return self._send_json(400, {"error": "missing id"})
        with lock:
            results = state["results"].setdefault(tid, [])
            results.append({
                "cmd_id": body.get("cmd_id"),
                "command": body.get("command"),
                "ok": body.get("ok"),
                "output": body.get("output"),
                "completed_at": time.time(),
            })
            del results[:-MAX_RESULTS_PER_TURTLE]
            save_state()
        return self._send_json(200, {"ok": True})

    def _handle_log_post(self, body):
        tid = str(body.get("id") or "")
        text = body.get("text")
        if not tid or not text:
            return self._send_json(400, {"error": "missing id or text"})
        with lock:
            entry = logs.setdefault(tid, {"text": "", "base": 0})
            entry["text"] += text
            if len(entry["text"]) > MAX_LOG_CHARS:
                trim = len(entry["text"]) - MAX_LOG_CHARS
                entry["text"] = entry["text"][trim:]
                entry["base"] += trim
        return self._send_json(200, {"ok": True})

    def _handle_log_get(self, tid, after):
        if not tid:
            return self._send_json(400, {"error": "missing id query param"})
        with lock:
            entry = logs.get(tid, {"text": "", "base": 0})
            after_n = max(int(after or 0), entry["base"])
            start = after_n - entry["base"]
            text = entry["text"][start:]
            cursor = entry["base"] + len(entry["text"])
        return self._send_json(200, {"text": text, "cursor": cursor})

    def _handle_cmd(self, tid, body):
        if not tid:
            return self._send_json(400, {"error": "missing id query param"})
        command = body.get("command")
        if not command:
            return self._send_json(400, {"error": "missing command"})
        cmd_id = next_cmd_id()
        with lock:
            state["queue"].setdefault(tid, []).append({"cmd_id": cmd_id, "command": command})
            save_state()
        return self._send_json(200, {"cmd_id": cmd_id})

    def _handle_cmd_all(self, body):
        command = body.get("command")
        if not command:
            return self._send_json(400, {"error": "missing command"})
        with lock:
            ids = list(state["turtles"].keys())
            queued = {}
            for tid in ids:
                cmd_id = next_cmd_id()
                state["queue"].setdefault(tid, []).append({"cmd_id": cmd_id, "command": command})
                queued[tid] = cmd_id
            save_state()
        return self._send_json(200, {"queued": queued})

    def _handle_status(self):
        with lock:
            now = time.time()
            out = {
                tid: {
                    "label": info.get("label"),
                    "last_seen": info.get("last_seen"),
                    "seconds_ago": round(now - info.get("last_seen", 0)),
                    "pending": len(state["queue"].get(tid, [])),
                }
                for tid, info in state["turtles"].items()
            }
        return self._send_json(200, out)

    def _handle_results(self, tid):
        if not tid:
            return self._send_json(400, {"error": "missing id query param"})
        with lock:
            out = list(state["results"].get(tid, []))
        return self._send_json(200, out)


def main():
    load_state()
    port = int(os.environ.get("RELAY_PORT", "8787"))
    httpd = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print(f"turtle relay listening on :{port}")
    httpd.serve_forever()


if __name__ == "__main__":
    main()
