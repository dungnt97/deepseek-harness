#!/bin/bash
# Prove the machine-level capabilities actually work, end to end:
#   A. a session on deepseek-v4.1-flash may read images
#   B. web_search reaches OpenCode Go through the loopback relay
#   C. AgentKit's skills reach the Harness, and a Finder-launched app can run `ak`
#
#   bash ~/deepseek-harness/local-setup/verify.sh
#
# It never prints, echoes or stores the API key: the live probe runs inside one
# python3 process that reads it from the credential store itself.
set -uo pipefail
UID_N="$(id -u)"
AGENT_LABEL="ai.dsh.opencode-go-search-relay"
PATH_LABEL="ai.dsh.gui-path"
fail=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=1; }
warn() { printf '  \033[33mwarn\033[0m %s\n' "$*"; }

echo "== service =="
STATE="$(launchctl print "gui/$UID_N/$AGENT_LABEL" 2>/dev/null | awk '/state = /{print $3; exit}')"
[ "$STATE" = "running" ] && ok "LaunchAgent state=running" || bad "LaunchAgent state=${STATE:-absent}"
if lsof -nP -iTCP:8787 -sTCP:LISTEN >/dev/null 2>&1; then
  ok "relay listening on 127.0.0.1:8787"
else
  bad "nothing listening on 127.0.0.1:8787 — check ~/.dsh/go-search-proxy.log"
fi
[ -x "$HOME/.dsh/bin/go-search-proxy.py" ] && ok "relay script installed" || bad "relay script missing"

echo "== GUI session PATH (what a Finder-launched app sees) =="
PATH_STATE="$(launchctl print "gui/$UID_N/$PATH_LABEL" 2>/dev/null | awk '/state = /{print $3; exit}')"
[ -n "$PATH_STATE" ] && ok "LaunchAgent loaded (state=${PATH_STATE})" || bad "LaunchAgent $PATH_LABEL is not loaded"
GUI_PATH="$(launchctl getenv PATH)"
case ":$GUI_PATH:" in
  *":$HOME/.local/bin:"*) ok "gui PATH exposes ~/.local/bin" ;;
  *) bad "gui PATH lacks ~/.local/bin — a shell call cannot run ak" ;;
esac
case ":$GUI_PATH:" in
  *:/opt/homebrew/bin:*) ok "gui PATH exposes /opt/homebrew/bin (Homebrew tools)" ;;
  *) warn "gui PATH lacks /opt/homebrew/bin — node and pnpm stay unreachable" ;;
esac
[ -x "$HOME/.local/bin/ak" ] && ok "AgentKit CLI installed at ~/.local/bin/ak" || warn "AgentKit CLI not found at ~/.local/bin/ak"
command -v node >/dev/null 2>&1 && ok "node $(node -v) reachable" || bad "node not on PATH — a session cannot run repo tooling"
command -v pnpm >/dev/null 2>&1 && ok "pnpm $(pnpm -v) reachable" || bad "pnpm not on PATH — run install.sh to install the pinned version"

echo "== OpenCode Go quota =="
if [ -x "$HOME/.dsh/bin/opencode-usage.py" ]; then
  if "$HOME/.dsh/bin/opencode-usage.py" >/dev/null 2>&1; then
    ok "quota endpoint answered: $("$HOME/.dsh/bin/opencode-usage.py" | sed -n '2p' | tr -s ' ')"
  else
    bad "quota check failed — run ~/.dsh/bin/opencode-usage.py to see why"
  fi
else
  bad "opencode-usage.py is not installed"
fi
[ -f "$HOME/.dsh/skills/usage/SKILL.md" ] && ok "/usage skill installed" || bad "/usage skill missing"

echo "== AgentKit skills =="
python3 - <<'PY'
import os, re, sys
root = os.path.expanduser("~/.dsh/skills")
valid = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
bad = 0
if not os.path.isdir(root):
    print("  \033[31mFAIL\033[0m ~/.dsh/skills does not exist — run ensure_skills.py"); sys.exit(1)
accepted, rejected = [], []
for name in sorted(os.listdir(root)):
    manifest = os.path.join(root, name, "SKILL.md")
    if not os.path.isfile(manifest):
        continue
    text = open(manifest, encoding="utf-8", errors="replace").read()
    block = re.match(r"\A---\r?\n(.*?)\r?\n---\r?\n", text, re.DOTALL)
    found = re.search(r"^name:[ \t]*(\S.*?)[ \t]*$", block.group(1), re.MULTILINE) if block else None
    declared = found.group(1).strip().strip("\"'") if found else None
    (accepted if declared and valid.match(declared) else rejected).append(declared or name)
if accepted:
    print(f"  \033[32mok\033[0m   {len(accepted)} skill(s) have a name the Harness catalog accepts")
else:
    print("  \033[31mFAIL\033[0m no usable skills — the catalog will stay empty"); bad = 1
if rejected:
    print(f"  \033[31mFAIL\033[0m {len(rejected)} skill(s) still carry a rejected name: {rejected[:5]}"); bad = 1
sys.exit(bad)
PY
[ $? -ne 0 ] && fail=1

echo "== settings (desktop profile patch) =="
# Newer Harness releases removed the harness-home settings.yaml: it is imported once into
# the active profile's Cordis patch, so the settings live there now.
python3 - <<'PY'
import pathlib, sys, yaml
patch = pathlib.Path.home()/".dsh/profiles/desktop/cordis.patch.yml"
if not patch.exists():
    print(f"  \033[31mFAIL\033[0m {patch} does not exist — launch DeepSeek Harness once"); sys.exit(1)
entries = yaml.safe_load(patch.read_text(encoding="utf-8")) or []
def entry(i): return next((e for e in entries if isinstance(e, dict) and e.get("id") == i), None)
bad = 0
llm = entry("llm-pi-ai") or {}
models = {m.get("id"): m.get("input")
          for p in ((llm.get("config") or {}).get("providers") or {}).values()
          for m in (p or {}).get("models") or []}
img = models.get("deepseek-v4.1-flash") or []
if "image" in img:
    print(f"  \033[32mok\033[0m   deepseek-v4.1-flash declares {img}")
else:
    print(f"  \033[31mFAIL\033[0m deepseek-v4.1-flash input={img!r} — read_image will refuse"); bad = 1
ws = (entry("web-search-deepseek") or {}).get("config") or {}
if str(ws.get("baseURL", "")).startswith("http://127.0.0.1:"):
    print(f"  \033[32mok\033[0m   web-search-deepseek -> {ws['baseURL']} (model={ws.get('model')})")
elif ws:
    print(f"  \033[31mFAIL\033[0m web-search-deepseek -> {ws.get('baseURL')} is not the relay"); bad = 1
else:
    print("  \033[31mFAIL\033[0m no web-search-deepseek entry — search will use the dead DeepSeek key"); bad = 1
sys.exit(bad)
PY
[ $? -ne 0 ] && fail=1

echo "== live probe (through the relay, plugin's own header set) =="
python3 - <<'PY'
import json, pathlib, sys, urllib.error, urllib.request, yaml
try:
    key = yaml.safe_load((pathlib.Path.home()/".dsh/.credentials.yaml").read_text())["refs"]["OPENCODE_API_KEY"]
except Exception as exc:
    print(f"  \033[31mFAIL\033[0m cannot read OPENCODE_API_KEY from the credential store: {exc}"); sys.exit(1)
body = {"model": "deepseek-v4-flash", "max_tokens": 300,
        "tools": [{"type": "web_search_20250305", "name": "web_search", "max_uses": 1}],
        "messages": [{"role": "user", "content": "Perform a web search for the query: opencode go"}]}
hdr = {"x-api-key": key, "authorization": f"Bearer {key}", "anthropic-version": "2023-06-01",
       "content-type": "application/json", "accept": "application/json"}
req = urllib.request.Request("http://127.0.0.1:8787/messages", data=json.dumps(body).encode(), headers=hdr)
try:
    with urllib.request.urlopen(req, timeout=180) as r:
        raw = r.read()
        d = json.loads(raw.decode("utf-8", "replace"))
except urllib.error.HTTPError as e:
    print(f"  \033[31mFAIL\033[0m relay answered HTTP {e.code}: {e.read().decode('utf-8','replace')[:160]}"); sys.exit(1)
except Exception as e:
    print(f"  \033[31mFAIL\033[0m relay unreachable: {type(e).__name__}: {e}"); sys.exit(1)
blocks = [b for b in d.get("content", []) if isinstance(b, dict)]
n = sum(len(b.get("content", [])) for b in blocks if b.get("type") == "web_search_tool_result"
        and isinstance(b.get("content"), list))
if n:
    print(f"  \033[32mok\033[0m   search returned {n} source(s) over the Go plan")
else:
    print(f"  \033[31mFAIL\033[0m no web_search_tool_result block; block types={[b.get('type') for b in blocks]}"); sys.exit(1)
PY
[ $? -ne 0 ] && fail=1

echo "== rebuild-on-update agent =="
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPDATE_STATE="$(launchctl print "gui/$UID_N/ai.dsh.repo-update" 2>/dev/null | awk '/state = /{print $3; exit}')"
[ -n "$UPDATE_STATE" ] && ok "LaunchAgent loaded (state=${UPDATE_STATE:-idle})" || bad "ai.dsh.repo-update is not loaded"
[ -x "$REPO_DIR/local-setup/update.sh" ] && ok "update.sh present" || bad "update.sh missing"
BRANCH_NOW="$(git -C "$REPO_DIR" branch --show-current 2>/dev/null)"
[ "$BRANCH_NOW" = "desktop-local" ] && ok "on branch desktop-local" || warn "on branch ${BRANCH_NOW:-unknown}; update.sh expects desktop-local"
BEHIND="$(git -C "$REPO_DIR" rev-list --count HEAD..upstream/master 2>/dev/null || echo '?')"
if [ "$BEHIND" = "0" ]; then
  ok "current with upstream/master"
elif [ "$BEHIND" = "?" ]; then
  warn "cannot compare with upstream/master — run: git -C \"$REPO_DIR\" fetch upstream"
else
  warn "$BEHIND commit(s) behind upstream/master — the update agent will build it"
fi
[ -z "$(git -C "$REPO_DIR" status --porcelain --untracked-files=no 2>/dev/null)" ] && ok "no uncommitted tracked changes" || warn "tracked files are modified; update.sh will refuse to run"

echo "== in-app update feed =="
source "$REPO_DIR/local-setup/signing.sh"
source "$REPO_DIR/local-setup/update-feed.sh"
if curl -s -m 3 -o /dev/null "$UPDATE_FEED_URL"; then ok "feed server answers on $UPDATE_FEED_URL"; else bad "ai.dsh.update-feed does not answer on $UPDATE_FEED_URL"; fi
if ensure_signing_identity >/dev/null 2>&1; then ok "signing identity $SIGNING_IDENTITY"; else bad "no local signing identity — run install.sh"; fi
if installed_reads_feed "/Applications/DeepSeek Harness.app"; then
  ok "installed application updates itself from the feed"
else
  warn "installed application predates the feed — the next update.sh run installs it directly"
fi

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[32mALL CHECKS PASSED\033[0m — images, web search, shell PATH, AgentKit skills, OpenCode Go quota, and the rebuild agent are ready.\n'
else
  printf '\033[31mSOME CHECKS FAILED\033[0m — see ~/deepseek-harness/local-setup/README.md (Troubleshooting).\n'
fi
exit "$fail"
