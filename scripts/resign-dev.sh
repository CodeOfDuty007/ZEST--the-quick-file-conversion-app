#!/bin/zsh
# Re-signs a built app with the local "Zest Dev" identity so its code requirement (and
# therefore its Accessibility / Input Monitoring grants) stays the same across rebuilds.
# codesign only finds identities in the keychain search list, so the dev keychain is
# added for the duration of the signing and the original list is restored afterwards.
set -euo pipefail

APP="$1"
KEYCHAIN="$HOME/Library/Keychains/zest-dev.keychain-db"
PASS="zest-dev-local"

[[ -f "$KEYCHAIN" ]] || { echo "No dev keychain; leaving ad-hoc signature. Run: make cert"; exit 0; }

ORIGINAL=("${(@f)$(security list-keychains -d user | sed -e 's/^ *"//' -e 's/"$//')}")
restore() { security list-keychains -d user -s "${ORIGINAL[@]}"; }
trap restore EXIT

security unlock-keychain -p "$PASS" "$KEYCHAIN"
security list-keychains -d user -s "$KEYCHAIN" "${ORIGINAL[@]}"
codesign --force --sign "Zest Dev" --options runtime --identifier org.zest.Zest "$APP"
