#!/bin/bash
# Rebuild and reinstall the local DeepSeek Harness application from the current branch.
#
# The application is built from source, so a new upstream commit means a new build.
# This script does the whole sequence and never leaves a half-installed application:
# the new bundle is built and signed *before* the installed one is touched, and a
# failed merge, install, or build stops with the installed application untouched.
#
#   bash ~/deepseek-harness/local-setup/update.sh
#   bash ~/deepseek-harness/local-setup/update.sh --force
#   bash ~/deepseek-harness/local-setup/update.sh --install-only
#   bash ~/deepseek-harness/local-setup/update.sh --dry-run
#
# It is driven by check-update.sh, which shows the alert and calls this on confirmation.
set -euo pipefail

SETUP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SETUP/.." && pwd)"
HOME_DIR="$HOME"
LOG="$HOME_DIR/.dsh/update.log"
LOCK="$HOME_DIR/.dsh/update.lock"
APP_ID="com.deepseek.harness.desktop"
APP_SOURCE="$REPO/apps/desktop/.desktop-build/targets/mac-arm64/local-artifacts/mac-arm64/DeepSeek Harness.app"
APP_TARGET="/Applications/DeepSeek Harness.app"
BRANCH="desktop-local"

# The LaunchAgent that drives this runs with launchd's minimal PATH, which carries no
# pnpm and no Homebrew node. Fall back to the login shell's PATH before anything needs
# them, so a confirmed update does not fail on a missing command.
if ! command -v pnpm >/dev/null 2>&1; then
  LOGIN_PATH="$(/bin/zsh -lc 'printf %s "$PATH"' 2>/dev/null || true)"
  export PATH="$HOME/.local/bin:/opt/homebrew/bin:${LOGIN_PATH:-/usr/bin:/bin}"
fi

mkdir -p "$HOME_DIR/.dsh"
exec >>"$LOG" 2>&1
printf '\n=== update started %s ===\n' "$(date '+%Y-%m-%d %H:%M:%S')"

say() { printf '%s\n' "$*"; }
notify() {
  # A banner, not a dialog: the update runs unattended once confirmed.
  /usr/bin/osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1 || true
}

FORCE=0
DRY_RUN=0
INSTALL_ONLY=0
for argument in "$@"; do
  case "$argument" in
    --force) FORCE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --install-only) INSTALL_ONLY=1 ;;
    *) say "unknown flag $argument (expected --force, --install-only, or --dry-run)"; exit 2 ;;
  esac
done

# One update at a time; a stale lock from a crashed run is reported rather than ignored.
if ! mkdir "$LOCK" 2>/dev/null; then
  say "another update is already running ($LOCK); remove it only if no update is active"
  exit 1
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

cd "$REPO"

# Sign and install the bundle at APP_SOURCE, replacing the installed application only
# after its signature verifies. Every caller reaches the swap through this one path.
install_bundle() {
  if [ ! -d "$APP_SOURCE" ]; then
    say "no bundle at $APP_SOURCE — run without --install-only to build one"
    notify "Update failed" "No bundle to install"
    exit 1
  fi

  say "signing ad-hoc"
  /usr/bin/codesign --force --deep --sign - "$APP_SOURCE"
  /usr/bin/codesign --verify --deep --strict "$APP_SOURCE"
  say "signature verified"

  # Only now is the installed application replaced, and only while it is not running.
  say "quitting the running application"
  /usr/bin/osascript -e 'quit app "DeepSeek Harness"' >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do
    /usr/bin/pgrep -f "MacOS/DeepSeek Harness" >/dev/null 2>&1 || break
    sleep 1
  done
  /usr/bin/pkill -f "MacOS/DeepSeek Harness" 2>/dev/null || true
  sleep 1

  say "installing to $APP_TARGET"
  rm -rf "$APP_TARGET"
  # APFS clones this copy, so 550 MB lands in well under a second.
  /usr/bin/ditto "$APP_SOURCE" "$APP_TARGET"
  /usr/bin/touch "$APP_TARGET"

  say "relaunching"
  /usr/bin/open "$APP_TARGET"
  /usr/bin/osascript -e "display notification \"$1\" with title \"DeepSeek Harness updated\"" >/dev/null 2>&1 || true
  printf '=== update finished %s ===\n' "$(date '+%Y-%m-%d %H:%M:%S')"
}

# Skipping the build is what makes this path seconds instead of minutes; the bundle it
# installs was signed by whichever build produced it, and is signed again here.
if [ "$INSTALL_ONLY" = "1" ]; then
  say "install-only: reusing the bundle at $APP_SOURCE"
  if [ "$DRY_RUN" = "1" ]; then
    say "dry run: would sign and install the existing bundle, then restart the app"
    exit 0
  fi
  install_bundle "Installed the existing build and relaunched"
  exit 0
fi

if [ "$(git branch --show-current)" != "$BRANCH" ]; then
  say "expected branch $BRANCH, found $(git branch --show-current); checkout it first"
  notify "Update stopped" "Not on $BRANCH"
  exit 1
fi

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  say "tracked files are modified; commit or discard them first:"
  git status --short --untracked-files=no
  notify "Update stopped" "Uncommitted changes in the repo"
  exit 1
fi

say "fetching upstream"
git fetch --quiet upstream

BEHIND="$(git rev-list --count "HEAD..upstream/master")"
if [ "$BEHIND" = "0" ]; then
  if [ "$FORCE" = "0" ]; then
    say "already up to date with upstream/master"
    [ "$DRY_RUN" = "1" ] || notify "DeepSeek Harness" "Already up to date — no rebuild needed"
    exit 0
  fi
  say "already up to date with upstream/master; --force rebuilds the current tree anyway"
else
  say "$BEHIND commit(s) behind upstream/master; merging into $BRANCH"
fi

# `--dry-run` stops before the branch or the installed application is touched, so the
# guards can be exercised without side effects.
if [ "$DRY_RUN" = "1" ]; then
  if [ "$BEHIND" = "0" ]; then
    say "dry run: would rebuild and reinstall the current tree (~3 minutes)"
  else
    say "dry run: would merge upstream/master into $BRANCH, rebuild, and reinstall (~3 minutes)"
  fi
  exit 0
fi

# A merge keeps every resolution already recorded, so upstream changes that were merged
# once do not have to be resolved again; only newly overlapping edits conflict.
if [ "$BEHIND" != "0" ]; then
  if ! git merge -m "merge: upstream/master into $BRANCH" upstream/master; then
    CONFLICTS="$(git diff --name-only --diff-filter=U | tr '\n' ' ')"
    git merge --abort || true
    say "merge conflicted in: $CONFLICTS"
    say "merge aborted; the installed application is untouched"
    notify "Update needs attention" "Merge conflict — run update.sh in a terminal"
    exit 1
  fi
fi

say "installing dependencies"
pnpm install --frozen-lockfile || pnpm install

# The Desktop package command imports `@deepseek-ai/node-addon-system/flock` while it loads,
# and a fresh checkout has no `lib/` there: the directory is Git-ignored and no install
# script creates it, so the package command dies before it can build anything.
say "building the native addon"
pnpm run build:native-system
pnpm --dir native/system run build:ts

# Measured at 2m56s on this machine: the TypeScript build, every package pack, the
# bundled-runtime install, and electron-builder.
say "building and packaging"
DSH_DESKTOP_APP_ID="$APP_ID" DSH_DESKTOP_LOCAL_UNSIGNED=1 \
  pnpm --dir apps/desktop run package:mac:arm64:dir

install_bundle "Rebuilt from upstream/master and relaunched"
