#!/usr/bin/env python3
"""
Idempotently ensure the two machine-local settings this setup needs, under whichever
settings model the installed Harness uses.

Older Harness releases read `~/.dsh/settings.yaml` directly; this script edits that file
as TEXT (not as a parsed document, because PyYAML cannot round-trip the comments that
explain why each block is there -- and those comments are the whole reason a later reader
does not delete the block).

Newer releases removed that file: on the next start a legacy `settings.yaml` is imported
once into the active profile's Cordis patch and renamed to `settings.yaml.imported`. The
same two settings then live in `~/.dsh/profiles/<profile>/cordis.patch.yml`, so this
script verifies them there instead (and appends the web-search entry when it is missing).

  1. `input: [text, image]` on the `deepseek-v4.1-flash` entry.
     Without it the model falls back to DEFAULT_INPUT=["text"] (it is in no bundled
     catalogue) and `read_image` refuses it by declaration alone -- even though the
     model demonstrably sees images (three solid PNGs answered Red/Blue/Green).

  2. The `web-search-deepseek` entry.
     Points search at the loopback relay, because Go's Messages endpoint requires
     `x-opencode-session` and the search plugin cannot send it.

Exit codes: 0 changed or already correct · 2 refusal (unparseable/lost anchor).
"""
import datetime
import pathlib
import shutil
import sys

HOME = pathlib.Path.home()
SETTINGS = HOME / ".dsh" / "settings.yaml"
DESKTOP_PATCH = HOME / ".dsh" / "profiles" / "desktop" / "cordis.patch.yml"

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

WEB_SEARCH_PATCH_ENTRY = """
# Web search via OpenCode Go (the plan this machine pays for) instead of a
# DeepSeek platform key that is no longer valid. The Go Messages endpoint
# requires `x-opencode-session`, which the search plugin cannot send (its config
# schema has no `headers` field), so `baseURL` points at a loopback relay that
# adds exactly that one header: ~/.dsh/bin/go-search-proxy.py
# Reinstall / re-check everything with: bash ~/deepseek-harness/local-setup/install.sh
- id: web-search-deepseek
  name: "@deepseek-ai/dsh-web-search-deepseek"
  config:
    apiKeyEnv: OPENCODE_API_KEY
    baseURL: http://127.0.0.1:8787
    model: deepseek-v4-flash
"""


def edit_legacy_document() -> int:
    """Edit the removed `~/.dsh/settings.yaml` while it still exists (pre-import Harness)."""
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


def find_entry(entries, entry_id):
    for entry in entries or []:
        if isinstance(entry, dict) and entry.get("id") == entry_id:
            return entry
    return None


def model_input(entries, model_id):
    entry = find_entry(entries, "llm-pi-ai")
    if entry is None:
        return None
    providers = (entry.get("config") or {}).get("providers") or {}
    for provider in providers.values():
        for model in (provider or {}).get("models") or []:
            if model.get("id") == model_id:
                return model.get("input")
    return None


def web_search_base(entries):
    entry = find_entry(entries, "web-search-deepseek")
    if entry is None:
        return None
    return (entry.get("config") or {}).get("baseURL")


def verify_profile_patch() -> int:
    """Verify (and repair) the settings the new Harness imported into the desktop patch."""
    if not DESKTOP_PATCH.exists():
        print(f"REFUSING: {DESKTOP_PATCH} does not exist — launch DeepSeek Harness once, "
              "or run this before the settings model changed", file=sys.stderr)
        return 2
    import yaml
    text = DESKTOP_PATCH.read_text(encoding="utf-8")
    entries = yaml.safe_load(text) or []
    if not isinstance(entries, list):
        print(f"REFUSING: {DESKTOP_PATCH} is not a patch entry list", file=sys.stderr)
        return 2

    changed = []
    if web_search_base(entries) is None:
        # Appending one entry is additive and cannot disturb the others; the `[]` root of a
        # profile that has never been edited needs to become a list first.
        if text.strip() == "[]":
            text = WEB_SEARCH_PATCH_ENTRY.lstrip("\n")
        else:
            if not text.endswith("\n"):
                text += "\n"
            text += WEB_SEARCH_PATCH_ENTRY
        ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        backup = DESKTOP_PATCH.with_name(f"cordis.patch.yml.pre-install-{ts}")
        shutil.copy2(DESKTOP_PATCH, backup)
        DESKTOP_PATCH.write_text(text, encoding="utf-8")
        entries = yaml.safe_load(text) or []
        changed.append("added web-search-deepseek -> loopback relay")

    image_input = model_input(entries, MODEL_ID)
    base = web_search_base(entries)

    if image_input is not None and "image" in image_input:
        print(f"  {MODEL_ID} input   = {image_input}")
    else:
        print(f"REFUSING: {MODEL_ID} input={image_input!r} in {DESKTOP_PATCH} — `read_image` "
              "will refuse it. The legacy import writes it from ~/.dsh/settings.yaml; restore "
              "that file from local-setup/assets/settings.reference.yaml and relaunch the app.",
              file=sys.stderr)
        return 2

    if base and str(base).startswith("http://127.0.0.1:"):
        print(f"  web-search-deepseek = {base} (profile patch)")
    else:
        print(f"REFUSING: web-search-deepseek -> {base!r} in {DESKTOP_PATCH} is not the relay",
              file=sys.stderr)
        return 2

    if changed:
        print("desktop profile patch updated: " + "; ".join(changed))
    else:
        print("desktop profile patch already correct — nothing written")
    return 0


def main() -> int:
    if SETTINGS.exists():
        return edit_legacy_document()
    return verify_profile_patch()


if __name__ == "__main__":
    raise SystemExit(main())
