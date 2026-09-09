#!/usr/bin/env python3
"""tools/stranger_walk/container/mcp_probe.py — drive the SAME @playwright/mcp
server the stranger's own `claude -p` session gets, directly, over the MCP
stdio JSON-RPC transport.

Found 2026-09-09, triaging sonnet-before-1 (v1.4): the stranger's browser
tool failed both real navigations with "Chromium distribution 'chrome' is
not found at /opt/google/chrome/chrome" — @playwright/mcp's default
`--browser` channel is the SYSTEM "chrome" install, which this image never
installed (only playwright's own managed chromium, via
`playwright install chromium`). The v1.4 selftest exercised Python
playwright directly (a different code path entirely, using the SAME
browser binary but a DIFFERENT driver/launch configuration) and never
caught this — it never actually invoked @playwright/mcp at all.

This script spawns the EXACT command run_container.sh writes into
mcp-config.json (npx @playwright/mcp@latest --headless --browser chromium
--user-data-dir <profile>) and speaks the standard MCP stdio protocol to
it directly: initialize, then two real tool calls (browser_navigate,
browser_take_screenshot) against the public entry point — the same two
tool calls a stranger's own navigation attempt makes. No Anthropic
credential is needed (this never goes through `claude` at all), keeping
selftest's existing no-credential contract intact while genuinely
exercising the stranger's real code path.

Usage: mcp_probe.py <profile-dir> <screenshot-out-path>
Exit 0 on a real, successful navigate+screenshot round trip; 1 otherwise
(prints the JSON-RPC error or exception to stderr).
"""
import json
import subprocess
import sys
import time

REQUEST_TIMEOUT_S = 45


def send(proc, msg):
    proc.stdin.write((json.dumps(msg) + "\n").encode("utf-8"))
    proc.stdin.flush()


def read_one(proc, want_id, deadline):
    """Reads JSON-RPC lines from proc.stdout until one matches want_id
    (skipping any server->client notifications, which have no "id")."""
    while time.time() < deadline:
        line = proc.stdout.readline()
        if not line:
            if proc.poll() is not None:
                raise RuntimeError(
                    f"MCP server exited early (code={proc.returncode}); "
                    f"stderr tail: {proc.stderr.read(4000).decode('utf-8', 'ignore')}"
                )
            continue
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if obj.get("id") == want_id:
            return obj
    raise TimeoutError(f"no MCP response for id={want_id} within {REQUEST_TIMEOUT_S}s")


def main():
    if len(sys.argv) != 3:
        print("usage: mcp_probe.py <profile-dir> <screenshot-out-path>", file=sys.stderr)
        return 2
    profile_dir, screenshot_out = sys.argv[1], sys.argv[2]

    # Identical command/args to run_container.sh's mcp-config.json — this
    # IS the stranger's own browser tool, not a lookalike.
    cmd = [
        "npx", "--yes", "@playwright/mcp@latest",
        "--headless", "--browser", "chromium",
        "--user-data-dir", profile_dir,
    ]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        send(proc, {
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "stranger-walk-mcp-probe", "version": "1.5"},
            },
        })
        init_resp = read_one(proc, 1, time.time() + REQUEST_TIMEOUT_S)
        if init_resp.get("error"):
            raise RuntimeError(f"initialize error: {init_resp['error']}")
        send(proc, {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})

        send(proc, {
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": {"name": "browser_navigate", "arguments": {"url": "https://softmax.com/paintbot"}},
        })
        nav_resp = read_one(proc, 2, time.time() + REQUEST_TIMEOUT_S)
        if nav_resp.get("error") or (nav_resp.get("result") or {}).get("isError"):
            raise RuntimeError(f"browser_navigate failed: {nav_resp.get('error') or nav_resp.get('result')}")

        send(proc, {
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": {"name": "browser_take_screenshot", "arguments": {}},
        })
        shot_resp = read_one(proc, 3, time.time() + REQUEST_TIMEOUT_S)
        if shot_resp.get("error") or (shot_resp.get("result") or {}).get("isError"):
            raise RuntimeError(f"browser_take_screenshot failed: {shot_resp.get('error') or shot_resp.get('result')}")

        # Persist whatever image content came back, if any, as proof.
        import base64
        content = (shot_resp.get("result") or {}).get("content") or []
        saved = False
        for block in content:
            if block.get("type") == "image" and block.get("data"):
                with open(screenshot_out, "wb") as f:
                    f.write(base64.b64decode(block["data"]))
                saved = True
                break
        print(
            f"[mcp_probe] OK: initialize + browser_navigate + browser_take_screenshot all succeeded "
            f"via the real @playwright/mcp process (screenshot_saved={saved})"
        )
        return 0
    except Exception as e:
        print(f"[mcp_probe] FAILED: {e}", file=sys.stderr)
        return 1
    finally:
        try:
            proc.terminate()
            proc.wait(timeout=5)
        except Exception:
            try:
                proc.kill()
            except Exception:
                pass


if __name__ == "__main__":
    sys.exit(main())
