#!/bin/bash
# Re-apply every machine-level piece this Harness needs, so a fresh checkout -- or a
# Harness update that rewrote its own config -- costs one command instead of an hour
# of rediscovery.
#
# Idempotent: run it as often as you like. It backs up settings.yaml before touching it.
#
#   bash ~/deepseek-harness/local-setup/install.sh
#
# What it installs, and why each piece exists, is in ~/deepseek-harness/local-setup/README.md.
set -euo pipefail

SETUP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_DIR="$HOME"
AGENT_LABEL="ai.dsh.opencode-go-search-relay"
PATH_LABEL="ai.dsh.gui-path"
PLIST_DST="$HOME_DIR/Library/LaunchAgents/$AGENT_LABEL.plist"
PATH_PLIST_DST="$HOME_DIR/Library/LaunchAgents/$PATH_LABEL.plist"
RELAY_DST="$HOME_DIR/.dsh/bin/go-search-proxy.py"
PATH_SCRIPT_DST="$HOME_DIR/.dsh/bin/set-gui-path.sh"
USAGE_DST="$HOME_DIR/.dsh/bin/opencode-usage.py"
USAGE_SKILL_DST="$HOME_DIR/.dsh/skills/usage/SKILL.md"
UPDATE_LABEL="ai.dsh.repo-update"
UPDATE_PLIST_DST="$HOME_DIR/Library/LaunchAgents/$UPDATE_LABEL.plist"
UID_N="$(id -u)"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# Reload one LaunchAgent, waiting for the label to disappear after bootout.
# launchd answers "Bootstrap failed: 5: Input/output error" when a bootstrap races an
# unfinished bootout, which would otherwise abort the whole install.
load_agent() {
  local label="$1" plist="$2"
  launchctl bootout "gui/$UID_N/$label" 2>/dev/null || true
  for _ in $(seq 1 25); do
    launchctl print "gui/$UID_N/$label" >/dev/null 2>&1 || break
    sleep 0.2
  done
  launchctl bootstrap "gui/$UID_N" "$plist"
}

say "1/10  relay -> $RELAY_DST"
mkdir -p "$HOME_DIR/.dsh/bin"
install -m 0755 "$SETUP/assets/go-search-proxy.py" "$RELAY_DST"
echo "     installed ($(wc -c < "$RELAY_DST" | tr -d ' ') bytes)"

say "2/10  LaunchAgent -> $PLIST_DST"
mkdir -p "$HOME_DIR/Library/LaunchAgents"
sed "s|__HOME__|$HOME_DIR|g" "$SETUP/assets/ai.dsh.opencode-go-search-relay.plist.in" > "$PLIST_DST"
plutil -lint "$PLIST_DST"

say "3/10  (re)load the service"
load_agent "$AGENT_LABEL" "$PLIST_DST"
launchctl enable "gui/$UID_N/$AGENT_LABEL" 2>/dev/null || true
# give KeepAlive a moment to bring the port up before anything probes it
for _ in 1 2 3 4 5 6 7 8 9 10; do
  lsof -nP -iTCP:8787 -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.5
done
echo "     state: $(launchctl print "gui/$UID_N/$AGENT_LABEL" 2>/dev/null | awk '/state = /{print $3; exit}')"

say "4/10  settings.yaml"
python3 "$SETUP/ensure_settings.py"

say "5/10  GUI session PATH -> $PATH_PLIST_DST"
# launchd hands every Finder-launched app only /usr/bin:/bin:/usr/sbin:/sbin, and the
# Harness shell tool inherits the application's environment, so without this the agent
# cannot reach node, pnpm, git, or the AgentKit CLI.
install -m 0755 "$SETUP/assets/set-gui-path.sh" "$PATH_SCRIPT_DST"
sed "s|__HOME__|$HOME_DIR|g" "$SETUP/assets/ai.dsh.gui-path.plist.in" > "$PATH_PLIST_DST"
plutil -lint "$PATH_PLIST_DST"
load_agent "$PATH_LABEL" "$PATH_PLIST_DST"
PATH_BEFORE="$(launchctl getenv PATH || true)"
"$PATH_SCRIPT_DST"
PATH_AFTER="$(launchctl getenv PATH || true)"
echo "     gui PATH: $PATH_AFTER"

say "6/10  pnpm"
# The Harness repo declares its package manager in `packageManager`; without a global
# pnpm a session cannot run `pnpm run …` at all. Install only when absent so a version
# the user chose deliberately is never silently replaced.
REPO="$(cd "$SETUP/.." && pwd)"
WANTED="$(python3 -c "import json;print(json.load(open('$REPO/package.json')).get('packageManager','').removeprefix('pnpm@'))" 2>/dev/null || true)"
[ -n "$WANTED" ] || WANTED="11.7.0"
PRESENT="$(pnpm --version 2>/dev/null || true)"
if [ -n "$PRESENT" ]; then
  echo "     pnpm $PRESENT already installed"
  [ "$PRESENT" = "$WANTED" ] || echo "     note: $REPO/package.json pins pnpm@$WANTED"
elif command -v npm >/dev/null 2>&1; then
  npm install -g "pnpm@$WANTED"
  echo "     installed pnpm $(pnpm --version)"
else
  echo "     skipped: no pnpm and no npm on PATH — install Node.js first"
fi

say "7/10  OpenCode Go quota -> $USAGE_DST"
# The subscription allowance has an official endpoint; nothing else reports it.
# `opencode stats` only covers that CLI's own local usage history.
install -m 0755 "$SETUP/assets/opencode-usage.py" "$USAGE_DST"
mkdir -p "$(dirname "$USAGE_SKILL_DST")"
install -m 0644 "$SETUP/assets/usage-SKILL.md" "$USAGE_SKILL_DST"
echo "     /usage skill installed"
"$USAGE_DST" || echo "     quota check failed; see the message above"

say "8/10  AgentKit skills -> $HOME_DIR/.dsh/skills"
python3 "$SETUP/ensure_skills.py"

say "9/10  rebuild-on-upstream-update agent -> $UPDATE_PLIST_DST"
# The application is built from source, so a new upstream commit needs a new build.
# The agent checks upstream every six hours and prompts once per new upstream state;
# confirming runs update.sh, which rebuilds and reinstalls without further input.
# A fresh clone carries only `origin`, and both scripts fetch this remote.
if ! git -C "$REPO" remote get-url upstream >/dev/null 2>&1; then
  git -C "$REPO" remote add upstream git@github.com:deepseek-ai/deepseek-harness.git
  git -C "$REPO" remote set-url --push upstream DISABLED_NO_PUSH
  echo "     added the fetch-only upstream remote"
fi
sed -e "s|__HOME__|$HOME_DIR|g" -e "s|__REPO__|$REPO|g" "$SETUP/assets/ai.dsh.repo-update.plist.in" > "$UPDATE_PLIST_DST"
plutil -lint "$UPDATE_PLIST_DST"
load_agent "$UPDATE_LABEL" "$UPDATE_PLIST_DST"
echo "     state: $(launchctl print "gui/$UID_N/$UPDATE_LABEL" 2>/dev/null | awk '/state = /{print $3; exit}')"

say "10/10  verification"
bash "$SETUP/verify.sh"

say "DONE — nothing else to set up. Re-run this command any time."
# launchctl setenv only reaches apps launched afterwards, so the hint is worth printing
# exactly when this run changed the PATH a running app already inherited.
if [ "$PATH_BEFORE" != "$PATH_AFTER" ]; then
  echo "     PATH changed: quit and reopen DeepSeek Harness.app for it to take effect."
fi
