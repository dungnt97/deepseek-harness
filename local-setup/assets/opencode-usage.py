#!/usr/bin/env python3
"""Report the OpenCode Go subscription quota for the plan this machine pays for.

OpenCode serves an official quota endpoint next to the model API:

    GET https://opencode.ai/zen/go/v1/usage
    {"usage":{"rolling":{"status":"ok","percent":10,"resetsAt":"…"},
              "weekly":{"status":"ok","percent":27,"resetsAt":"…"},
              "monthly":{"status":"ok","percent":13,"resetsAt":"…"}}}

That is the subscription allowance, not local consumption: `opencode stats` reports
tokens and cost the opencode CLI recorded in its own database, which says nothing
about how much of the Go plan is left. This script reads the same key the Harness
uses (`OPENCODE_API_KEY`, falling back to `OPENCODE_GO_API_KEY`, then the Harness
credential store) and never prints it.

    python3 ~/.dsh/bin/opencode-usage.py
    python3 ~/.dsh/bin/opencode-usage.py --json
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import pathlib
import re
import sys
import urllib.error
import urllib.request

DEFAULT_ENDPOINT = "https://opencode.ai/zen/go/v1/usage"
ENDPOINT_ENV = "OPENCODE_USAGE_URL"
KEY_NAMES = ("OPENCODE_API_KEY", "OPENCODE_GO_API_KEY")
CREDENTIALS = pathlib.Path.home() / ".dsh" / ".credentials.yaml"
WINDOWS = ("rolling", "weekly", "monthly")


def credential_store_key(name: str) -> str | None:
    """Read one key from the Harness credential store, with or without PyYAML."""
    if not CREDENTIALS.is_file():
        return None
    text = CREDENTIALS.read_text(encoding="utf-8", errors="replace")
    try:
        import yaml  # noqa: PLC0415 - optional dependency, absent from system python3

        refs = (yaml.safe_load(text) or {}).get("refs") or {}
        value = refs.get(name)
        return value if isinstance(value, str) and value else None
    except Exception:
        # The store is a flat `refs:` map of `NAME: value`; parse that shape alone.
        block = re.search(r"^refs:\s*$((?:\n[ \t]+.*)*)", text, re.MULTILINE)
        if block is None:
            return None
        found = re.search(rf"^[ \t]+{re.escape(name)}:[ \t]*(\S.*?)[ \t]*$", block.group(1), re.MULTILINE)
        return found.group(1).strip().strip("\"'") if found else None


def api_key() -> str:
    for name in KEY_NAMES:
        value = os.environ.get(name)
        if value:
            return value
    for name in KEY_NAMES:
        value = credential_store_key(name)
        if value:
            return value
    raise SystemExit(f"opencode-usage: none of {', '.join(KEY_NAMES)} is set or stored in {CREDENTIALS}")


def fetch(endpoint: str, key: str) -> dict:
    request = urllib.request.Request(endpoint, headers={
        "authorization": f"Bearer {key}",
        "accept": "application/json",
        "user-agent": "deepseek-harness/1.0",
    })
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", "replace")[:200]
        raise SystemExit(f"opencode-usage: HTTP {error.code} from {endpoint}: {detail}") from error
    except Exception as error:  # noqa: BLE001 - one diagnostic line for every transport failure
        raise SystemExit(f"opencode-usage: {type(error).__name__}: {error}") from error


def remaining(resets_at: str, now: dt.datetime) -> str:
    """Render a reset instant as local time plus a compact countdown."""
    try:
        when = dt.datetime.fromisoformat(resets_at.replace("Z", "+00:00")).astimezone()
    except ValueError:
        return resets_at
    delta = when - now
    minutes = int(delta.total_seconds() // 60)
    if minutes < 0:
        countdown = "due"
    elif minutes < 60:
        countdown = f"{minutes}m"
    elif minutes < 60 * 48:
        countdown = f"{minutes // 60}h {minutes % 60:02d}m"
    else:
        countdown = f"{minutes // (60 * 24)}d {minutes // 60 % 24:02d}h"
    return f"{when:%d %b %H:%M} (in {countdown})"


def bar(percent: float, width: int = 20) -> str:
    filled = max(0, min(width, round(width * percent / 100)))
    return "[" + "#" * filled + "-" * (width - filled) + "]"


def main() -> int:
    parser = argparse.ArgumentParser(description="Show the OpenCode Go subscription quota.")
    parser.add_argument("--json", action="store_true", help="emit the raw API response")
    parser.add_argument("--endpoint", default=os.environ.get(ENDPOINT_ENV, DEFAULT_ENDPOINT))
    arguments = parser.parse_args()

    payload = fetch(arguments.endpoint, api_key())
    usage = payload.get("usage") if isinstance(payload, dict) else None
    if not isinstance(usage, dict) or not usage:
        raise SystemExit(f"opencode-usage: unexpected response: {json.dumps(payload)[:200]}")

    if arguments.json:
        json.dump(payload, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        return 0

    now = dt.datetime.now(dt.timezone.utc).astimezone()
    print("OpenCode Go — subscription quota")
    for name in [*WINDOWS, *(key for key in usage if key not in WINDOWS)]:
        window = usage.get(name)
        if not isinstance(window, dict):
            continue
        percent = float(window.get("percent") or 0)
        status = window.get("status") or "unknown"
        line = f"  {name:<8} {percent:5.1f}% used  {bar(percent)}  {100 - percent:5.1f}% left"
        if window.get("resetsAt"):
            line += f"  resets {remaining(str(window['resetsAt']), now)}"
        if status != "ok":
            line += f"  [{status}]"
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
