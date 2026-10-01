#!/bin/bash
# Create (once) and unlock the self-signed code-signing identity local builds are signed with.
#
# Squirrel.Mac installs an update only when the new bundle satisfies the running application's
# designated requirement. An ad-hoc signature pins one build's cdhash, so no later build could
# ever satisfy it; a certificate keeps the requirement `identifier … and certificate leaf = H"…"`
# stable across builds. The certificate is untrusted (no Developer ID), which codesign and
# Squirrel's requirement check accept; Gatekeeper never evaluates a locally built bundle.
#
# The identity lives in its own keychain with a generated password, so signing never prompts
# and the login keychain is untouched.
#
#   source local-setup/signing.sh && ensure_signing_identity
#   -> sets SIGNING_KEYCHAIN and SIGNING_IDENTITY (SHA-1 of the certificate)

SIGNING_DIR="$HOME/.dsh/signing"
SIGNING_KEYCHAIN="$SIGNING_DIR/dsh-local.keychain-db"
SIGNING_NAME="DSH Local Code Signing"

ensure_signing_identity() {
  local password_file="$SIGNING_DIR/keychain-password"
  mkdir -p "$SIGNING_DIR"
  chmod 700 "$SIGNING_DIR"
  if [ ! -f "$SIGNING_KEYCHAIN" ]; then
    local work
    work="$(mktemp -d)"
    /usr/bin/openssl rand -hex 32 > "$password_file"
    chmod 600 "$password_file"
    cat > "$work/cert.cnf" <<EOF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$SIGNING_NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$work/cert.cnf" \
      -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
    /usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" \
      -out "$work/identity.p12" -passout pass:transfer 2>/dev/null
    /usr/bin/security create-keychain -p "$(cat "$password_file")" "$SIGNING_KEYCHAIN"
    /usr/bin/security set-keychain-settings "$SIGNING_KEYCHAIN"
    /usr/bin/security unlock-keychain -p "$(cat "$password_file")" "$SIGNING_KEYCHAIN"
    /usr/bin/security import "$work/identity.p12" -k "$SIGNING_KEYCHAIN" -P transfer -T /usr/bin/codesign >/dev/null
    /usr/bin/security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
      -k "$(cat "$password_file")" "$SIGNING_KEYCHAIN" >/dev/null
    rm -rf "$work"
  fi
  /usr/bin/security unlock-keychain -p "$(cat "$password_file")" "$SIGNING_KEYCHAIN"
  SIGNING_IDENTITY="$(/usr/bin/security find-identity -p codesigning "$SIGNING_KEYCHAIN" \
    | awk -v name="\"$SIGNING_NAME\"" 'index($0, name) { print $2; exit }')"
  if [ -z "$SIGNING_IDENTITY" ]; then
    echo "signing: no \"$SIGNING_NAME\" identity in $SIGNING_KEYCHAIN" >&2
    return 1
  fi
}

# Print the certificate leaf hash a bundle's designated requirement pins, or nothing.
bundle_signing_leaf() {
  /usr/bin/codesign -dr - "$1" 2>&1 | sed -n 's/.*certificate leaf = H"\([0-9a-fA-F]*\)".*/\1/p' | tr 'a-f' 'A-F'
}
