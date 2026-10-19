#!/bin/zsh
# Credentials must already be stored by the owner with notarytool store-credentials.
set -euo pipefail
PROJECT_ROOT="${0:A:h:h}"
cd "$PROJECT_ROOT"
if [[ $# != 2 || ! -f "$1" || "$1" != *-release.dmg ]]; then
    print -u2 'Usage: ./scripts/notarize-release.sh <release.dmg> <keychain-profile>'; exit 2
fi
DMG="${1:A}"
PROFILE="$2"
# Reject local test bundles before uploading anything.
MOUNT="$(mktemp -d "$PROJECT_ROOT/build/notary-mount.XXXXXX")"
ATTACHED=0
function cleanup() {
    if (( ATTACHED )); then hdiutil detach "$MOUNT" -quiet || true; fi
    rmdir "$MOUNT" 2>/dev/null || true
}
trap cleanup EXIT
hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$MOUNT" -quiet
ATTACHED=1
SIGNATURE="$(codesign -dvvv "$MOUNT/剪巢.app" 2>&1)"
if [[ "$SIGNATURE" != *'Authority=Developer ID Application:'* || "$SIGNATURE" != *'runtime'* || "$SIGNATURE" != *'Timestamp='* ]]; then
    print -u2 'Refusing to notarize a bundle without a valid distribution signature.'; exit 2
fi
codesign --verify --deep --strict "$MOUNT/剪巢.app"
hdiutil detach "$MOUNT" -quiet; ATTACHED=0
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
# Stapling fails if Apple did not accept the submission; set -e stops here.
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
shasum -a 256 "$DMG" > "$DMG.sha256"
print 'Notarization and Gatekeeper verification passed.'
