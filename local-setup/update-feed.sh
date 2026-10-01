#!/bin/bash
# The machine-local update feed the application's own updater reads.
#
# update.sh publishes each signed build here as `nightly-mac.yml` plus the zip it names, the
# files electron-updater's generic provider requests for the `nightly` channel. The
# ai.dsh.update-feed LaunchAgent serves the directory on 127.0.0.1:$UPDATE_FEED_PORT.
#
#   source local-setup/update-feed.sh && publish_update_feed "<app bundle>" "<version>"

UPDATE_FEED_DIR="$HOME/.dsh/update-feed"
UPDATE_FEED_PORT=47823
UPDATE_FEED_URL="http://127.0.0.1:$UPDATE_FEED_PORT/"

# Whether an installed application can take a build through its own updater: it reads this
# feed and its designated requirement pins the local signing certificate. Needs
# SIGNING_IDENTITY from signing.sh's ensure_signing_identity.
installed_reads_feed() {
  local config="$1/Contents/Resources/app-update.yml"
  [ -f "$config" ] && grep -qF "$UPDATE_FEED_URL" "$config" \
    && [ "$(bundle_signing_leaf "$1")" = "$SIGNING_IDENTITY" ]
}

publish_update_feed() {
  local app="$1" version="$2"
  local name="DeepSeek-Harness-$version-mac-arm64.zip"
  mkdir -p "$UPDATE_FEED_DIR"
  # Same archive form electron-builder produces for Squirrel.Mac: the bundle as the zip's root.
  rm -f "$UPDATE_FEED_DIR/$name.partial"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$UPDATE_FEED_DIR/$name.partial"
  mv "$UPDATE_FEED_DIR/$name.partial" "$UPDATE_FEED_DIR/$name"
  local sha512 size
  sha512="$(/usr/bin/openssl dgst -sha512 -binary "$UPDATE_FEED_DIR/$name" | /usr/bin/base64)"
  size="$(stat -f %z "$UPDATE_FEED_DIR/$name")"
  # The manifest is replaced last and atomically, so a reader never sees it name a partial zip.
  cat > "$UPDATE_FEED_DIR/nightly-mac.yml.partial" <<EOF
version: $version
files:
  - url: $name
    sha512: $sha512
    size: $size
path: $name
sha512: $sha512
releaseDate: '$(date -u +%Y-%m-%dT%H:%M:%S.000Z)'
EOF
  mv "$UPDATE_FEED_DIR/nightly-mac.yml.partial" "$UPDATE_FEED_DIR/nightly-mac.yml"
  # Only the published zip is kept; an application mid-download keeps its open file.
  find "$UPDATE_FEED_DIR" -maxdepth 1 -name 'DeepSeek-Harness-*.zip' ! -name "$name" -delete
}
