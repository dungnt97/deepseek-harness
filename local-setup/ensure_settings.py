#!/usr/bin/env python3
"""
Idempotently bring ~/.dsh/settings.yaml up to the two settings this machine needs.

It edits TEXT, not a parsed document, because PyYAML cannot round-trip the comments
that explain why each block is there -- and those comments are the whole reason a
later reader does not delete the block. Both edits are presence-checked first, so
running this twice is a no-op and running it after a Harness update that rewrote
settings.yaml restores them.

  1. `input: [text, image]` on the `deepseek-v4.1-flash` entry.
     Without it the model falls back to DEFAULT_INPUT=["text"] (it is in no bundled
     catalogue) and `read_image` refuses it by declaration alone -- even though the
     model demonstrably sees images (three solid PNGs answered Red/Blue/Green).

  2. The top-level `web-search-deepseek:` block.
     Points search at the loopback relay, because Go's Messages endpoint requires
     `x-opencode-session` and the search plugin cannot send it.

Exit codes: 0 changed or already correct · 2 refusal (unparseable/lost anchor).
"""
import datetime
import pathlib
import shutil
import sys

SETTINGS = pathlib.Path.home() / ".dsh" / "settings.yaml"

MODEL_ID = "deepseek-v4.1-flash"
INPUT_LINE = "          input: [text, image]\n"
INPUT_COMMENT = (
    "          # MEASURED 2026-09-15: this model SEES images. Three solid 8x8 PNGs\n"
    "          # (red/blue/green) posted to /zen/go/v1/chat/completions with this entry's own\n"
    "          # x-opencode-session answered 'Red'/'Blue'/'Green' correctly -- and a text-only\n"
    "          # control on the same route returned 200, so the endpoint and key are sound.\n"
    "          # Without this line the harness falls back to DEFAULT_INPUT=[\"text\"] (the model is\n"
    "          # in no bundled catalogue) and `read_image` refuses it by declaration alone.\n"
)

WEB_SEARCH_BLOCK = """
# Web search via OpenCode Go (the plan this machine pays for) instead of a
# DeepSeek platform key that is no longer valid. The Go Messages endpoint
# requires `x-opencode-session`, which the search plugin cannot send (its config
# schema has no `headers` field), so `baseURL` points at a loopback relay that
# adds exactly that one header: ~/.dsh/bin/go-search-proxy.py
# Reinstall / re-check everything with: bash ~/deepseek-harness/local-setup/install.sh
web-search-deepseek:
  baseURL: http://127.0.0.1:8787
  model: deepseek-v4-flash
  apiKeyEnv: OPENCODE_API_KEY
"""


def main() -> int:
    if not SETTINGS.exists():
        print(f"REFUSING: {SETTINGS} does not exist", file=sys.stderr)
        return 2
    original = SETTINGS.read_text(encoding="utf-8")
    text = original
    changed = []

    # ---- 1. the model's declared modalities ------------------------------------------------
    head, sep, tail = text.partition(f"- id: {MODEL_ID}\n")
    if not sep:
        print(f"REFUSING: no `- id: {MODEL_ID}` entry to attach `input:` to", file=sys.stderr)
        return 2
    block, sep2, rest = tail.partition("        - id: ")     # up to the next entry, if any
    if "input:" not in block:
        anchor = "          maxTokens:"
        at = block.find(anchor)
        if at < 0:
            print(f"REFUSING: `{MODEL_ID}` entry has no maxTokens line to anchor to",
                  file=sys.stderr)
            return 2
        eol = block.index("\n", at) + 1
        block = block[:eol] + INPUT_COMMENT + INPUT_LINE + block[eol:]
        changed.append(f"declared image input on {MODEL_ID}")
    text = head + sep + block + sep2 + rest

    # ---- 2. the web-search endpoint ---------------------------------------------------------
    if "\nweb-search-deepseek:" not in "\n" + text:
        if not text.endswith("\n"):
            text += "\n"
        text += WEB_SEARCH_BLOCK
        changed.append("added web-search-deepseek -> loopback relay")

    if text == original:
        print("settings.yaml already correct — nothing written")
    else:
        try:
            import yaml
            yaml.safe_load(text)
        except Exception as exc:                                    # noqa: BLE001
            print(f"REFUSING: the edit would not parse: {exc}", file=sys.stderr)
            return 2
        ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        backup = SETTINGS.with_name(f"settings.yaml.pre-install-{ts}")
        shutil.copy2(SETTINGS, backup)
        SETTINGS.write_text(text, encoding="utf-8")
        print(f"settings.yaml updated (backup {backup.name}): " + "; ".join(changed))

    import yaml
    cfg = yaml.safe_load(SETTINGS.read_text(encoding="utf-8"))
    ws = cfg.get("web-search-deepseek") or {}
    models = {m.get("id"): m.get("input")
              for p in (cfg.get("llm-pi-ai", {}).get("providers", {}) or {}).values()
              for m in (p.get("models") or [])}
    print(f"  {MODEL_ID} input   = {models.get(MODEL_ID)}")
    print(f"  web-search-deepseek = {ws.get('baseURL')} · model={ws.get('model')} · key={ws.get('apiKeyEnv')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
