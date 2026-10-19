#!/bin/zsh
# Direct downloads may be unnotarized; signed releases require Developer ID.
set -euo pipefail
PROJECT_ROOT="${0:A:h:h}"
cd "$PROJECT_ROOT"
MODE="${1:-direct}"
if [[ "$MODE" != direct && "$MODE" != candidate && "$MODE" != release ]]; then
    print -u2 'Usage: ./scripts/package-release.sh direct|candidate|release [--existing-app]'; exit 2
fi
if [[ "$MODE" == release && -z "${JIANCHAO_SIGNING_IDENTITY:-}" ]]; then
    print -u2 'Set JIANCHAO_SIGNING_IDENTITY to a Developer ID Application identity first.'; exit 2
fi
export JIANCHAO_ARCHS="${JIANCHAO_ARCHS:-universal}"
APP_PATH="$PROJECT_ROOT/build/剪巢.app"
if [[ "${2:-}" == --existing-app ]]; then
    [[ -d "$APP_PATH" ]] || { print -u2 'Build the app first.'; exit 2; }
    if [[ "$JIANCHAO_ARCHS" == universal ]]; then
        APP_ARCHS=" $(lipo -archs "$APP_PATH/Contents/MacOS/Jianchao") "
        [[ "$APP_ARCHS" == *' arm64 '* && "$APP_ARCHS" == *' x86_64 '* ]] || { print -u2 'The existing app must include arm64 and x86_64.'; exit 2; }
    fi
else
    [[ $# -le 1 ]] || { print -u2 'Unknown packaging argument.'; exit 2; }
    ./scripts/build-app.sh release
fi
codesign --verify --deep --strict "$APP_PATH"
if [[ "$MODE" == release ]]; then
    SIGNATURE="$(codesign -dvvv "$APP_PATH" 2>&1)"
    if [[ "$SIGNATURE" != *'Authority=Developer ID Application:'* || "$SIGNATURE" != *'runtime'* || "$SIGNATURE" != *'Timestamp='* ]]; then
        print -u2 'Public release requires Developer ID Application, hardened runtime and secure timestamp.'; exit 2
    fi
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
STAGE="$(mktemp -d "$PROJECT_ROOT/build/package-stage.XXXXXX")"
trap 'find "$STAGE" -depth -delete' EXIT
/usr/bin/ditto "$APP_PATH" "$STAGE/剪巢.app"
cp LICENSE "$STAGE/LICENSE.txt"
ln -s /Applications "$STAGE/Applications"
if [[ "$MODE" == candidate ]]; then
    cat > "$STAGE/安装说明.txt" <<'TEXT'
剪巢 · 本地测试候选版

将「剪巢.app」拖入 Applications 后启动。首次使用需在系统设置中允许粘贴所需权限。
当前包使用本地开发签名，尚未获得 Apple 公证，仅用于本机回归测试，不作为公开下载版本。
请勿同时运行项目 build 目录和 Applications 中的两个副本。
历史数据仅保存在本机。反馈：87975531@qq.com（hck）。
TEXT
elif [[ "$MODE" == direct ]]; then
    cat > "$STAGE/安装说明.txt" <<'TEXT'
剪巢 · 安装说明

1. 将「剪巢.app」拖入 Applications（应用程序）后启动。
2. 当前安装包未经过 Apple 公证。首次打开时，macOS 可能提示无法验证开发者或阻止打开。
   若你确认安装包来自作者提供的链接，可在尝试打开后前往「系统设置 → 隐私与安全」，
   找到对应提示并按系统指引允许打开。不同系统版本的按钮名称可能不同。
   受组织管理的设备可能不允许此操作。
3. 启动后，按应用内提示允许剪贴板访问及直接粘贴所需的系统权限。
4. 应用常驻菜单栏。请只保留一个运行副本；升级前先退出旧版，再替换应用。

历史数据默认仅保存在本机。
© 2026 hck · MIT License（完整许可见 LICENSE.txt）
问题反馈：87975531@qq.com
TEXT
else
    cat > "$STAGE/安装说明.txt" <<'TEXT'
将「剪巢.app」拖入 Applications 后启动，应用常驻菜单栏。
首次使用请按应用提示允许所需权限。请勿同时运行两个副本。
历史数据仅保存在本机。反馈：87975531@qq.com（hck）。
TEXT
fi
if [[ "$MODE" == direct ]]; then
    OUTPUT="$PROJECT_ROOT/build/剪巢-$VERSION-$JIANCHAO_ARCHS.dmg"
else
    OUTPUT="$PROJECT_ROOT/build/剪巢-$VERSION-$JIANCHAO_ARCHS-$MODE.dmg"
fi
hdiutil create -volname "剪巢 $VERSION" -srcfolder "$STAGE" -format UDZO -ov "$OUTPUT"
hdiutil verify "$OUTPUT"
shasum -a 256 "$OUTPUT" > "$OUTPUT.sha256"
print -r -- "$OUTPUT"
if [[ "$MODE" == release ]]; then print 'Next: ./scripts/notarize-release.sh <dmg-path> <notarytool-keychain-profile>'; fi
