#!/bin/zsh
# Creates a self-signed "Zest Dev" code-signing identity in its own keychain so that
# Accessibility / Input Monitoring grants survive rebuilds. Local development only.
# The login keychain and the keychain search list are not modified.
set -euo pipefail

NAME="Zest Dev"
KEYCHAIN="$HOME/Library/Keychains/zest-dev.keychain-db"
PASS="zest-dev-local"

if [[ -f "$KEYCHAIN" ]] && security find-identity -p codesigning "$KEYCHAIN" | grep -q "$NAME"; then
  echo "Identity '$NAME' already exists in $KEYCHAIN"
  exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CNF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config "$WORK/openssl.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/zest.p12" -passout "pass:$PASS" 2>/dev/null

security create-keychain -p "$PASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"   # no auto-lock timeout
security unlock-keychain -p "$PASS" "$KEYCHAIN"
security import "$WORK/zest.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$PASS" "$KEYCHAIN" >/dev/null

echo "Created '$NAME' in $KEYCHAIN"
security find-identity -p codesigning "$KEYCHAIN"
