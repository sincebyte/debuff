#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="debuff.app"
DIST_DIR="${DIST_DIR:-$ROOT/dist}"
APP_PATH="$DIST_DIR/$APP_NAME"
BINARY_SRC="$ROOT/.build/release/SedentaryDebuff"
BUNDLE_SRC="$ROOT/.build/release/SedentaryDebuff_SedentaryDebuff.bundle"

echo "==> swift build -c release"
swift build -c release

if [[ ! -x "$BINARY_SRC" ]]; then
	echo "error: missing executable: $BINARY_SRC" >&2
	exit 1
fi
if [[ ! -d "$BUNDLE_SRC" ]]; then
	echo "error: missing resource bundle: $BUNDLE_SRC" >&2
	exit 1
fi

echo "==> assemble $APP_PATH"
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS"
cp "$BINARY_SRC" "$APP_PATH/Contents/MacOS/SedentaryDebuff"
chmod +x "$APP_PATH/Contents/MacOS/SedentaryDebuff"
# 资源 bundle 必须放进 Contents/Resources：SwiftPM 生成的 Bundle.module
# 依次在 Bundle.main.resourceURL（即 Contents/Resources）等位置查找，
# 放到 Contents/MacOS 会找不到并以 "unable to find bundle" 崩溃。
mkdir -p "$APP_PATH/Contents/Resources"
INNER_BUNDLE="$APP_PATH/Contents/Resources/SedentaryDebuff_SedentaryDebuff.bundle"
cp -R "$BUNDLE_SRC" "$APP_PATH/Contents/Resources/"
# SPM 资源包已在 Contents/Info.plist 生成合法 BNDL（缺失时才补全）。
# 切勿在 bundle 根额外放文件，否则 codesign 会以
# "unsealed contents present in the bundle root" 失败。
BUNDLE_PLIST="$INNER_BUNDLE/Contents/Info.plist"
if [[ ! -f "$BUNDLE_PLIST" ]]; then
	mkdir -p "$(dirname "$BUNDLE_PLIST")"
	cp "$ROOT/App/ResourceBundle-Info.plist" "$BUNDLE_PLIST"
fi

cp "$ROOT/App/Info.plist" "$APP_PATH/Contents/Info.plist"

echo "==> AppIcon.icns（源图：App/appicon.png）"
APP_ICON_SRC="$ROOT/App/appicon.png"
if [[ ! -f "$APP_ICON_SRC" ]]; then
	echo "error: missing app icon png: $APP_ICON_SRC" >&2
	exit 1
fi
ICON_TMP="$(mktemp -d "${TMPDIR:-/tmp}/sedentarydebuff-icon.XXXXXX")"
trap 'rm -rf "$ICON_TMP"' EXIT
ICONSET="$ICON_TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
sips -z 16 16 "$APP_ICON_SRC" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32 "$APP_ICON_SRC" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$APP_ICON_SRC" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64 "$APP_ICON_SRC" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$APP_ICON_SRC" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 "$APP_ICON_SRC" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$APP_ICON_SRC" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 "$APP_ICON_SRC" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$APP_ICON_SRC" --out "$ICONSET/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$APP_ICON_SRC" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET" -o "$ICON_TMP/AppIcon.icns" 2>/dev/null \
	|| echo "warning: iconutil failed; skipping app icon" || true
mkdir -p "$APP_PATH/Contents/Resources"
if [[ -f "$ICON_TMP/AppIcon.icns" ]]; then
	cp "$ICON_TMP/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
else
	# 图标缺失时移除 plist 引用，避免空引用
	/usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$APP_PATH/Contents/Info.plist" 2>/dev/null || true
fi

echo "==> ad-hoc codesign"
if command -v codesign >/dev/null 2>&1; then
	codesign --force --sign - "$INNER_BUNDLE"
	codesign --force --deep --sign - "$APP_PATH"
else
	echo "warning: codesign not found; skip signing"
fi

echo "Done: $APP_PATH"
echo "安装: cp -R \"$APP_PATH\" /Applications/"
