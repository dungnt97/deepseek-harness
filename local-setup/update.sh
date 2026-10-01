#!/bin/bash
# Rebuild the local DeepSeek Harness application from the current branch and deliver it.
#
# The application is built from source, so a new upstream commit means a new build.
# Every build is signed with the local identity (signing.sh) and then delivered one of two ways:
#   - the installed application already reads the local feed: the build is published to
#     ~/.dsh/update-feed and the application's own updater offers it (Check for Updates,
#     download progress, Install and Restart);
#   - otherwise (first install, or an older ad-hoc build): the bundle replaces
#     /Applications directly, which also makes later builds arrive through the feed.
# A failed merge or build stops with the installed application untouched.
#
#   bash ~/deepseek-harness/local-setup/update.sh
#   bash ~/deepseek-harness/local-setup/update.sh --force
#   bash ~/deepseek-harness/local-setup/update.sh --install-only
#   bash ~/deepseek-harness/local-setup/update.sh --dry-run
#
# It is driven by check-update.sh, which runs it when upstream moves.
set -euo pipefail

SETUP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SETUP/.." && pwd)"
HOME_DIR="$HOME"
LOG="$HOME_DIR/.dsh/update.log"
LOCK="$HOME_DIR/.dsh/update.lock"
APP_ID="com.deepseek.harness.desktop"
APP_SOURCE="$REPO/apps/desktop/.desktop-build/targets/mac-arm64/artifacts/mac-arm64/DeepSeek Harness.app"
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
source "$SETUP/signing.sh"
source "$SETUP/update-feed.sh"

# Sign APP_SOURCE with the local identity and verify it.
sign_bundle() {
  ensure_signing_identity
  say "signing with $SIGNING_NAME ($SIGNING_IDENTITY)"
  /usr/bin/codesign --force --deep --sign "$SIGNING_IDENTITY" --keychain "$SIGNING_KEYCHAIN" "$APP_SOURCE"
  /usr/bin/codesign --verify --deep --strict "$APP_SOURCE"
  say "signature verified"
}

# Sign and install the bundle at APP_SOURCE, replacing the installed application only
# after its signature verifies. Every direct install reaches the swap through this one path.
install_bundle() {
  if [ ! -d "$APP_SOURCE" ]; then
    say "no bundle at $APP_SOURCE — run without --install-only to build one"
    notify "Update failed" "No bundle to install"
    exit 1
  fi

  sign_bundle

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
# installs is signed again here and replaces /Applications directly, bypassing the feed.
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

# This branch edits no upstream file (the local build mode lives in local-setup/desktop-build),
# so a conflict here means an upstream file was edited by hand and must be reverted.
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

# Every build carries a newer version than the last, so the application's updater (which
# never downgrades) sees it as an update: <product version>.<date>.<time>, the form
# apps/desktop/scripts/desktop-build-version.mjs validates.
PRODUCT_VERSION="$(node -p "require('./apps/desktop/package.json').version")"
case "$PRODUCT_VERSION" in
  *-*) BUILD_VERSION="$PRODUCT_VERSION." ;;
  *) BUILD_VERSION="$PRODUCT_VERSION-test." ;;
esac
BUILD_VERSION="$BUILD_VERSION$(date +%Y%m%d).$((10#$(date +%H%M%S)))"

# Measured at 2m56s on this machine: the TypeScript build, every package pack, the
# bundled-runtime install, and electron-builder. The --import hook swaps Developer ID
# signing, notarization, and the update channel for a local build without editing
# apps/desktop; see local-setup/desktop-build/register.mjs.
say "building and packaging $BUILD_VERSION"
DSH_DESKTOP_APP_ID="$APP_ID" \
DSH_LOCAL_UPDATE_FEED_URL="$UPDATE_FEED_URL" \
NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }--import=$REPO/local-setup/desktop-build/register.mjs" \
  pnpm --dir apps/desktop run package:mac:arm64:dir --build-version "$BUILD_VERSION"

ensure_signing_identity
if installed_reads_feed "$APP_TARGET"; then
  sign_bundle
  say "publishing $BUILD_VERSION to $UPDATE_FEED_DIR"
  publish_update_feed "$APP_SOURCE" "$BUILD_VERSION"
  notify "DeepSeek Harness $BUILD_VERSION is ready" "Install it from DeepSeek Harness › Check for Updates…"
  printf '=== update published %s ===\n' "$(date '+%Y-%m-%d %H:%M:%S')"
else
  say "the installed application does not read the local feed yet; installing directly"
  install_bundle "Rebuilt $BUILD_VERSION and relaunched"
fi
