#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h}"
BUILD_DIR="$PROJECT_DIR/build"
APP="$BUILD_DIR/WordPop.app"
CONTENTS="$APP/Contents"
ARCH="$(uname -m)"
MIN_OS="13.0"
WORK="${TMPDIR:-/tmp}/wordpop-build-$$"

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$WORK"

swiftc \
  -Osize \
  -whole-module-optimization \
  -target "${ARCH}-apple-macosx${MIN_OS}" \
  -module-cache-path "$WORK/mcp" \
  -framework AppKit \
  -framework AudioToolbox \
  -framework CoreText \
  -framework QuartzCore \
  "$PROJECT_DIR/Sources/main.swift" \
  -o "$CONTENTS/MacOS/WordPop"

strip -x "$CONTENTS/MacOS/WordPop"
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS/Info.plist"

# App 图标（精简尺寸，控制包体；菜单栏图标由代码绘制不占资源）
ICON_SRC="$PROJECT_DIR/Resources/AppIcon-1024.png"
if [[ -f "$ICON_SRC" ]]; then
  mkdir -p "$WORK/icon.iconset"
  sips -z 16 16   "$ICON_SRC" --out "$WORK/icon.iconset/icon_16x16.png" >/dev/null
  sips -z 32 32   "$ICON_SRC" --out "$WORK/icon.iconset/icon_16x16@2x.png" >/dev/null
  sips -z 32 32   "$ICON_SRC" --out "$WORK/icon.iconset/icon_32x32.png" >/dev/null
  sips -z 64 64   "$ICON_SRC" --out "$WORK/icon.iconset/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$ICON_SRC" --out "$WORK/icon.iconset/icon_128x128.png" >/dev/null
  sips -z 256 256 "$ICON_SRC" --out "$WORK/icon.iconset/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$ICON_SRC" --out "$WORK/icon.iconset/icon_256x256.png" >/dev/null
  sips -z 512 512 "$ICON_SRC" --out "$WORK/icon.iconset/icon_256x256@2x.png" >/dev/null
  # 不再打 512/1024 大图，显著减小 icns
  iconutil -c icns "$WORK/icon.iconset" -o "$CONTENTS/Resources/AppIcon.icns" 2>/dev/null || true
fi

plutil -lint "$CONTENTS/Info.plist" >/dev/null
xattr -cr "$APP" 2>/dev/null || true

SIGN_ID=""
if security find-identity -v -p codesigning 2>/dev/null | grep -q 'WindowTile Signing'; then
  SIGN_ID="WindowTile Signing"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q 'Apple Development'; then
  SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep 'Apple Development' | head -1 | awk '{print $2}')
fi
if [[ -n "$SIGN_ID" ]]; then
  codesign --force --deep --sign "$SIGN_ID" --identifier "app.local.wordpop" --timestamp=none "$APP"
  echo "signed with: $SIGN_ID"
else
  codesign --force --sign - --timestamp=none --identifier "app.local.wordpop" "$APP"
fi

echo "── build ok ──"
echo "app: $APP"
du -sh "$APP"
echo -n "bin: "
wc -c < "$CONTENTS/MacOS/WordPop" | awk '{printf "%.1f KB\n", $1/1024}'
echo -n "icon: "
if [[ -f "$CONTENTS/Resources/AppIcon.icns" ]]; then
  wc -c < "$CONTENTS/Resources/AppIcon.icns" | awk '{printf "%.1f KB\n", $1/1024}'
else
  echo "(none)"
fi
