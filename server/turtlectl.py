#!/usr/bin/env python3
"""
turtlectl.py -- operator CLI for the turtle relay server (see relay.py).

Usage:
  turtlectl.py list
  turtlectl.py send <id> <command...>
  turtlectl.py send-all <command...>
  turtlectl.py results <id> [-n N]
  turtlectl.py watch <id>
  turtlectl.py console <id>   -- live screen feed; type a command + enter to send it

Reads RELAY_URL and RELAY_TOKEN from the environment; --url/--token override.
"""
import argparse
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.request


def request(url, token, method="GET", body=None):
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        print(f"error: HTTP {e.code}: {e.read().decode('utf-8', 'replace')}", file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as e:
        print(f"error: could not reach relay: {e.reason}", file=sys.stderr)
        sys.exit(1)


def print_result(r):
    status = "ok" if r.get("ok") else "ERR"
    print(f"[{status}] {r.get('command')}\n{r.get('output')}\n")


def main():
    p = argparse.ArgumentParser(description="Operator CLI for the turtle relay.")
    p.add_argument("--url", default=os.environ.get("RELAY_URL", "http://localhost:8787"))
    p.add_argument("--token", default=os.environ.get("RELAY_TOKEN"))
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("list")

    sp = sub.add_parser("send")
    sp.add_argument("id")
    sp.add_argument("command", nargs="+")

    sa = sub.add_parser("send-all")
    sa.add_argument("command", nargs="+")

    rp = sub.add_parser("results")
    rp.add_argument("id")
    rp.add_argument("-n", type=int, default=10)

    wp = sub.add_parser("watch")
    wp.add_argument("id")

    cp = sub.add_parser("console")
    cp.add_argument("id")

    args = p.parse_args()
    if not args.token:
        print("error: set RELAY_TOKEN or pass --token", file=sys.stderr)
        sys.exit(1)
    url = args.url.rstrip("/")

    if args.cmd == "list":
        status = request(f"{url}/status", args.token)
        if not status:
            print("no turtles have checked in yet")
        for tid, info in sorted(status.items(), key=lambda kv: kv[0]):
            label = info.get("label") or "(unlabeled)"
            print(f"{tid:>6}  {label:<20} last seen {info['seconds_ago']}s ago  pending={info['pending']}")

    elif args.cmd == "send":
        command = " ".join(args.command)
        res = request(f"{url}/cmd?id={args.id}", args.token, "POST", {"command": command})
        print(f"queued {res['cmd_id']} on turtle {args.id}: {command}")

    elif args.cmd == "send-all":
        command = " ".join(args.command)
        res = request(f"{url}/cmd_all", args.token, "POST", {"command": command})
        print(f"queued on {len(res['queued'])} turtle(s): {command}")

    elif args.cmd == "results":
        results = request(f"{url}/results?id={args.id}", args.token)
        for r in results[-args.n:]:
            print_result(r)

    elif args.cmd == "watch":
        seen = 0
        print(f"watching turtle {args.id} (ctrl-c to stop)")
        try:
            while True:
                results = request(f"{url}/results?id={args.id}", args.token)
                for r in results[seen:]:
                    print_result(r)
                seen = len(results)
                time.sleep(2)
        except KeyboardInterrupt:
            pass

    elif args.cmd == "console":
        stop = threading.Event()
        cursor = [0]

        def poll_loop():
            last_err = None
            while not stop.is_set():
                try:
                    req = urllib.request.Request(f"{url}/log?id={args.id}&after={cursor[0]}")
                    req.add_header("Authorization", f"Bearer {args.token}")
                    with urllib.request.urlopen(req, timeout=10) as resp:
                        res = json.loads(resp.read().decode("utf-8"))
                    text = res.get("text", "")
                    if text:
                        sys.stdout.write(text)
                        sys.stdout.flush()
                    cursor[0] = res.get("cursor", cursor[0])
                    if last_err:
                        print("\n[console: reconnected]", file=sys.stderr)
                        last_err = None
                except Exception as e:
                    if str(e) != last_err:
                        print(f"\n[console: poll error: {e}]", file=sys.stderr)
                        last_err = str(e)
                stop.wait(1)

        poller = threading.Thread(target=poll_loop, daemon=True)
        poller.start()

        print(f"live console for turtle {args.id} -- type a command and press enter to "
              "send it; ctrl-d or ctrl-c to stop")
        try:
            while True:
                try:
                    line = input().strip()
                except EOFError:
                    break
                if not line:
                    continue
                try:
                    req = urllib.request.Request(
                        f"{url}/cmd?id={args.id}",
                        data=json.dumps({"command": line}).encode("utf-8"),
                        method="POST",
                    )
                    req.add_header("Authorization", f"Bearer {args.token}")
                    req.add_header("Content-Type", "application/json")
                    with urllib.request.urlopen(req, timeout=10) as resp:
                        res = json.loads(resp.read().decode("utf-8"))
                    print(f"[queued {res['cmd_id']}]")
                except Exception as e:
                    print(f"[error queuing command: {e}]", file=sys.stderr)
        except KeyboardInterrupt:
            pass
        finally:
            stop.set()


if __name__ == "__main__":
    main()
