#!/bin/zsh
set -euo pipefail
PROJECT_ROOT="${0:A:h:h}"
cd "$PROJECT_ROOT"
CONFIGURATION="${1:-release}"
mkdir -p .build/module-cache .build/cache build
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/module-cache"
export SWIFT_MODULECACHE_PATH="$PROJECT_ROOT/.build/module-cache"
ARCH_MODE="${JIANCHAO_ARCHS:-native}"
ARCHITECTURES=()
case "$ARCH_MODE" in
    native) ARCHITECTURES=("$(uname -m)") ;;
    universal) ARCHITECTURES=(arm64 x86_64) ;;
    arm64|x86_64) ARCHITECTURES=("$ARCH_MODE") ;;
    *) print -u2 'JIANCHAO_ARCHS must be native, universal, arm64 or x86_64'; exit 2 ;;
esac
BINARIES=()
for ARCHITECTURE in "${ARCHITECTURES[@]}"; do
    swift build --product Jianchao -c "$CONFIGURATION" --arch "$ARCHITECTURE" --build-system native --disable-sandbox --cache-path "$PROJECT_ROOT/.build/cache" --config-path "$PROJECT_ROOT/.build/config" --security-path "$PROJECT_ROOT/.build/security"
    BIN_DIR="$(swift build -c "$CONFIGURATION" --arch "$ARCHITECTURE" --show-bin-path --build-system native --disable-sandbox --cache-path "$PROJECT_ROOT/.build/cache" --config-path "$PROJECT_ROOT/.build/config" --security-path "$PROJECT_ROOT/.build/security")"
    BINARIES+=("$BIN_DIR/Jianchao")
done
APP_PATH="$PROJECT_ROOT/build/剪巢.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
if (( ${#BINARIES[@]} > 1 )); then
    lipo -create "${BINARIES[@]}" -output "$APP_PATH/Contents/MacOS/Jianchao"
else
    cp "${BINARIES[1]}" "$APP_PATH/Contents/MacOS/Jianchao"
fi
cp App/Info.plist "$APP_PATH/Contents/Info.plist"
cp LICENSE "$APP_PATH/Contents/Resources/LICENSE.txt"
for resource in "$BIN_DIR"/*.bundle; do
    if [[ -d "$resource" ]]; then cp -R "$resource" "$APP_PATH/Contents/Resources/"; fi
done
cp App/AppIcon.icns "$APP_PATH/Contents/Resources/AppIcon.icns"
SIGNING_IDENTITY="${JIANCHAO_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" && -f .build/signing/identity.json ]]; then
    /usr/libexec/PlistBuddy -c 'Set :JianchaoSigningMode local' "$APP_PATH/Contents/Info.plist"
    python3 scripts/sign-local-app.py "$APP_PATH"
elif [[ -z "$SIGNING_IDENTITY" || "$SIGNING_IDENTITY" == "-" ]]; then
    codesign --force --deep --sign - "$APP_PATH"
else
    /usr/libexec/PlistBuddy -c 'Set :JianchaoSigningMode distribution' "$APP_PATH/Contents/Info.plist"
    codesign --force --deep --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP_PATH"
fi
codesign --verify --deep --strict "$APP_PATH"
print -r -- "$APP_PATH"
