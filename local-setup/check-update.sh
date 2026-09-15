#!/bin/bash
# Ask, at most once per upstream state, whether to rebuild the local application.
#
# The application is built from source, so a new upstream commit means a new build.
# This checks upstream, and when it has moved shows one alert with a real Update
# button; confirming hands the work to update.sh, which does the whole sequence.
#
#   bash ~/deepseek-harness/local-setup/check-update.sh
#
# Driven by the ai.dsh.repo-update LaunchAgent. A silent run (no terminal, nothing
# new) is the normal outcome.
set -uo pipefail

SETUP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SETUP/.." && pwd)"
STATE="$HOME/.dsh/update-notified"
LOCK="$HOME/.dsh/update.lock"

cd "$REPO" || exit 0

# An update in progress already has its own notification; never stack a prompt on it.
[ -d "$LOCK" ] && exit 0

git fetch --quiet upstream 2>/dev/null || exit 0
UPSTREAM_SHA="$(git rev-parse upstream/master 2>/dev/null)" || exit 0
BEHIND="$(git rev-list --count "HEAD..upstream/master" 2>/dev/null)" || exit 0
[ "${BEHIND:-0}" = "0" ] && exit 0

# One prompt per upstream state: "Later" is remembered until upstream moves again.
[ -f "$STATE" ] && [ "$(cat "$STATE")" = "$UPSTREAM_SHA" ] && exit 0

SUBJECT="DeepSeek Harness"
MESSAGE="$BEHIND new commit(s) on upstream/master.\\n\\nRebuild and reinstall the application now?\\nThis takes a few minutes and restarts the app."

ANSWER="$(/usr/bin/osascript \
  -e 'tell application "System Events" to activate' \
  -e "display dialog \"$MESSAGE\" buttons {\"Later\", \"Update\"} default button \"Update\" with title \"$SUBJECT\" giving up after 600" 2>/dev/null || true)"

case "$ANSWER" in
  *"button returned:Update"*)
    printf '%s\n' "$UPSTREAM_SHA" > "$STATE"
    /usr/bin/osascript -e "display notification \"Rebuilding from upstream/master — the app restarts when it finishes\" with title \"$SUBJECT update started\"" >/dev/null 2>&1 || true
    # Foreground, deliberately. launchd tears down a job's whole process group when the
    # job's main process exits, which killed a detached `nohup` child at its first
    # `git fetch` (SIGTERM, exit before any build). Staying alive keeps the update in
    # this job's group; the job's exit code then reports the update's outcome.
    /bin/bash "$SETUP/update.sh"
    ;;
  *)
    printf '%s\n' "$UPSTREAM_SHA" > "$STATE"
    ;;
esac
