#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="SedentaryDebuff.app"
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
cp -R "$BUNDLE_SRC" "$APP_PATH/Contents/MacOS/"
# SPM 资源包默认无 Info.plist，codesign 会拒绝；补全为合法 BNDL 后先签内层再签 .app
cp "$ROOT/App/ResourceBundle-Info.plist" \
	"$APP_PATH/Contents/MacOS/SedentaryDebuff_SedentaryDebuff.bundle/Info.plist"

cp "$ROOT/App/Info.plist" "$APP_PATH/Contents/Info.plist"

echo "==> ad-hoc codesign"
if command -v codesign >/dev/null 2>&1; then
	INNER="$APP_PATH/Contents/MacOS/SedentaryDebuff_SedentaryDebuff.bundle"
	codesign --force --sign - "$INNER"
	codesign --force --deep --sign - "$APP_PATH"
else
	echo "warning: codesign not found; skip signing"
fi

echo "Done: $APP_PATH"
echo "安装: cp -R \"$APP_PATH\" /Applications/"
