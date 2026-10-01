#!/bin/bash
# Build the local application when upstream moves.
#
# The application is built from source, so a new upstream commit means a new build.
# When the installed application reads the local update feed, the build runs unattended:
# update.sh publishes it, and the application's own updater offers it (Check for Updates,
# download progress, Install and Restart). An installed application that predates the feed
# would be replaced and restarted directly, so that case still asks first, once per
# upstream state.
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

# One build or prompt per upstream state: "Later" is remembered until upstream moves again.
[ -f "$STATE" ] && [ "$(cat "$STATE")" = "$UPSTREAM_SHA" ] && exit 0

source "$SETUP/signing.sh"
source "$SETUP/update-feed.sh"
ensure_signing_identity >/dev/null 2>&1 || exit 0
if installed_reads_feed "/Applications/DeepSeek Harness.app"; then
  printf '%s\n' "$UPSTREAM_SHA" > "$STATE"
  # Foreground: launchd kills a detached child when this job exits (see below).
  if ! /bin/bash "$SETUP/update.sh"; then
    rm -f "$STATE"
    /usr/bin/osascript -e "display notification \"The background build did not finish — see ~/.dsh/update.log\" with title \"DeepSeek Harness update failed\"" >/dev/null 2>&1 || true
  fi
  exit 0
fi

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
    if ! /bin/bash "$SETUP/update.sh"; then
      # An update that did not finish must be offered again; keeping the state recorded
      # above would silence this upstream state until upstream moved on its own.
      rm -f "$STATE"
      /usr/bin/osascript -e "display notification \"The update did not finish — see ~/.dsh/update.log\" with title \"$SUBJECT update failed\"" >/dev/null 2>&1 || true
    fi
    ;;
  *)
    printf '%s\n' "$UPSTREAM_SHA" > "$STATE"
    ;;
esac
