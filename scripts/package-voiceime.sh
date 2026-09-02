#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="VoiceIME.app"
DIST_DIR="${DIST_DIR:-$ROOT/dist}"
APP_PATH="$DIST_DIR/$APP_NAME"
BINARY_SRC="$ROOT/.build/release/VoiceIME"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Library/Input Methods}"
INSTALL_PATH="$INSTALL_DIR/$APP_NAME"

echo "==> swift build -c release --product VoiceIME"
swift build -c release --product VoiceIME

if [[ ! -x "$BINARY_SRC" ]]; then
	echo "error: missing executable: $BINARY_SRC" >&2
	exit 1
fi

echo "==> assemble $APP_PATH"
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS"
cp "$BINARY_SRC" "$APP_PATH/Contents/MacOS/VoiceIME"
chmod +x "$APP_PATH/Contents/MacOS/VoiceIME"
cp "$ROOT/App/VoiceIME-Info.plist" "$APP_PATH/Contents/Info.plist"

echo "==> ad-hoc codesign"
if command -v codesign >/dev/null 2>&1; then
	if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
		echo "   signing with identity: $CODESIGN_IDENTITY"
		codesign --force --deep --sign "$CODESIGN_IDENTITY" "$APP_PATH"
	else
		codesign --force --deep --sign - "$APP_PATH"
	fi
else
	echo "warning: codesign not found; skip signing"
fi

if [[ "${1:-}" == "--install" ]]; then
	echo "==> install to $INSTALL_PATH"
	rm -rf "$INSTALL_PATH"
	cp -R "$APP_PATH" "$INSTALL_PATH"
	echo "==> register + enable input source"
	"$INSTALL_PATH/Contents/MacOS/VoiceIME" --install || {
		echo "error: register/enable failed" >&2
		exit 1
	}
	echo "Done."
	echo "下一步（在目标 App 里验证）:"
	echo "  1. 系统设置/菜单栏输入法，把当前 App 切到 VoiceIME（可能需要几秒才出现）"
	echo "  2. 光标放好后按 F8：绿线=caret 矩形，随后自动插入 VoiceIME-PoC✅"
	echo "  3. 日志: /tmp/voiceime.log"
	exit 0
fi

echo "Done: $APP_PATH"
echo "安装: INSTALL_DIR=... $0 --install"
