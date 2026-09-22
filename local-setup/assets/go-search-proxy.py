#!/usr/bin/env python3
"""
A 30-line loopback relay that lets the Harness's web search reach OpenCode Go.

WHY THIS EXISTS
---------------
OpenCode Go's Anthropic-Messages endpoint (`https://opencode.ai/zen/go/v1/messages`)
requires an `x-opencode-session` header on EVERY request -- it answers
`400 MissingSessionID` without one, for every model, listed or not. The Harness's
web-search plugin cannot send it: its config schema is
`{apiKey, apiKeyEnv, baseURL, model, apiVersion, maxTokens, maxUses}` -- there is
no `headers` field -- and its fetch() header set is hard-coded to
`x-api-key` + `authorization` + `anthropic-version` + `content-type` + `accept`.

This is a KNOWN gap, not a misconfiguration. OpenCode's own Go documentation
lists DeepSeek Harness under "Known Problematic Clients":
    "Session information arrives on some model paths, but is missing on others.
     We recognize its native header; the remaining work is to send it across all
     adapters."  -- discussion #5495

So the plugin is pointed at THIS relay instead of at OpenCode directly, and the
relay adds the one missing header. It passes the caller's own `x-api-key` /
`authorization` through untouched, so it never needs -- and never sees stored --
the API key itself. Bind is loopback-only, and the Harness's own proxy policy
always bypasses loopback, so there is no routing loop.

CONFIGURE
---------
The `web-search-deepseek` entry points at this relay:
    baseURL: http://127.0.0.1:8787
    model: deepseek-v4-flash
    apiKeyEnv: OPENCODE_API_KEY
Older Harness releases read it from `~/.dsh/settings.yaml`; newer ones import that
document once into the active profile's Cordis patch
(`~/.dsh/profiles/desktop/cordis.patch.yml`) and rename it to `settings.yaml.imported`.

RUN
---
    python3 ~/.dsh/bin/go-search-proxy.py &        # or: --port N, --session ID
Reads the session id from the settings document at startup.
"""
import argparse
import http.server
import json
import pathlib
import sys
import urllib.error
import urllib.request

UPSTREAM = "https://opencode.ai/zen/go/v1"
SETTINGS = pathlib.Path.home() / ".dsh" / "settings.yaml"
PROFILE_PATCH = pathlib.Path.home() / ".dsh" / "profiles" / "desktop" / "cordis.patch.yml"
HOP_BY_HOP = {"host", "content-length", "connection", "transfer-encoding",
              "keep-alive", "proxy-authenticate", "proxy-authorization",
              "te", "trailer", "upgrade"}


def _session_from_llm_entry(providers):
    for prof in (providers or {}).values():
        sid = (prof.get("headers") or {}).get("x-opencode-session")
        if sid:
            return sid
    return None


def default_session():
    """The session id the LLM provider already sends; read, never invented.

    Reads the legacy `settings.yaml` while it exists, then the profile patch newer
    Harness releases import it into.
    """
    import yaml
    try:
        if SETTINGS.exists():
            cfg = yaml.safe_load(SETTINGS.read_text(encoding="utf-8")) or {}
            sid = _session_from_llm_entry(cfg.get("llm-pi-ai", {}).get("providers"))
            if sid:
                return sid
    except Exception as exc:                                    # noqa: BLE001
        print(f"warning: could not read a session id from {SETTINGS}: {exc}",
              file=sys.stderr)
    try:
        entries = yaml.safe_load(PROFILE_PATCH.read_text(encoding="utf-8")) or []
        for entry in entries:
            if isinstance(entry, dict) and entry.get("id") == "llm-pi-ai":
                sid = _session_from_llm_entry((entry.get("config") or {}).get("providers"))
                if sid:
                    return sid
    except Exception as exc:                                    # noqa: BLE001
        print(f"warning: could not read a session id from {PROFILE_PATCH}: {exc}",
              file=sys.stderr)
    return None


class Relay(http.server.BaseHTTPRequestHandler):
    session = None
    protocol_version = "HTTP/1.1"

    def _relay(self):
        body = b""
        n = int(self.headers.get("Content-Length") or 0)
        if n:
            body = self.rfile.read(n)
        headers = {k: v for k, v in self.headers.items()
                   if k.lower() not in HOP_BY_HOP
                   # The relay does not decode. Upstream answers `Content-Encoding: br`
                   # for Node's default `Accept-Encoding: gzip, deflate, br`, and while
                   # forwarding that header DOES work for the Node client, it makes the
                   # relay untestable from anything without a brotli decoder and turns an
                   # encoding mismatch into an opaque "not valid JSON". Asking for
                   # identity keeps this a pass-through in both directions. A search
                   # response is tens of KB; the compression is worth less than that.
                   and k.lower() != "accept-encoding"}
        if self.session:
            headers["x-opencode-session"] = self.session
        # Cloudflare in front of opencode.ai answers 403 / error 1010 to a generic
        # HTTP-library signature (urllib's default, and the *inbound* caller's default
        # too). Overridden unconditionally rather than defaulted: OpenCode Go's own docs
        # ask a client to "identify itself with its own user agent ... rather than a
        # generic SDK or HTTP-library name", and the plugin's own undici signature is
        # just "node". This is the one header the relay owns.
        headers["User-Agent"] = "deepseek-harness/1.0"
        url = UPSTREAM + self.path
        req = urllib.request.Request(url, data=body or None, headers=headers,
                                     method=self.command)
        try:
            with urllib.request.urlopen(req, timeout=300) as r:
                status, payload = r.status, r.read()
                up_headers = list(r.headers.items())
        except urllib.error.HTTPError as e:
            status, payload = e.code, e.read()
            up_headers = list(e.headers.items())
        except Exception as e:                                   # noqa: BLE001
            msg = json.dumps({"error": {"type": "RelayError", "message": str(e)}}).encode()
            status, payload, up_headers = 502, msg, [("Content-Type", "application/json")]
        print(f"  {self.command} {self.path} -> {status} ({len(payload)}B)", flush=True)
        self.send_response(status)
        # 🔴 EVERY upstream response header except the hop-by-hop set, not just
        # Content-Type. urllib never decompresses, and Node's fetch sends
        # `Accept-Encoding: gzip, br` by default -- so the first version of this relay
        # handed the harness raw gzip bytes WITHOUT the `Content-Encoding` that would
        # have told it to inflate them, and the plugin reported
        # `Unexpected token '', "..." is not valid JSON`. Forwarding the header is the
        # fix; stripping Accept-Encoding outbound would also work but would drop an
        # optimisation the client asked for.
        for k, v in up_headers:
            if k.lower() not in HOP_BY_HOP and k.lower() != "content-length":
                self.send_header(k, v)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    do_POST = _relay
    do_GET = _relay

    def log_message(self, *a):     # silence the default per-request stderr line
        pass


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--session", default=None,
                    help="x-opencode-session value (default: read from the settings document)")
    a = ap.parse_args()
    Relay.session = a.session or default_session()
    if not Relay.session:
        print("ERROR: no session id. Pass --session or set it in the settings document.",
              file=sys.stderr)
        return 2
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", a.port), Relay)
    print(f"opencode-go search relay on http://127.0.0.1:{a.port} -> {UPSTREAM}"
          f"  (session ...{Relay.session[-6:]})", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
