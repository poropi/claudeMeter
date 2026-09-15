#!/bin/bash
# claudeMeter をビルドして ClaudeMeter.app を組み立てる。
# 依存は Xcode のツールチェーンのみ（SwiftPM も外部ライブラリも使わない）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# メニューバー常駐 (LSUIElement) の置き場は ~/Applications が既定。第1引数で変えられる。
APP="${1:-$HOME/Applications/ClaudeMeter.app}"
MACOS_DIR="$APP/Contents/MacOS"

SWIFTC="$(xcrun -f swiftc)"
SDK="$(xcrun --show-sdk-path)"

mkdir -p "$MACOS_DIR"


"$SWIFTC" -O -parse-as-library \
    -target arm64-apple-macos14.0 \
    -sdk "$SDK" \
    -o "$MACOS_DIR/ClaudeMeter" \
    "$ROOT"/Sources/ClaudeMeter/*.swift

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>claudeMeter</string>
    <key>CFBundleDisplayName</key><string>claudeMeter</string>
    <key>CFBundleIdentifier</key><string>io.github.poropi.claudemeter</string>
    <key>CFBundleExecutable</key><string>ClaudeMeter</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <!-- メニューバー常駐。Dock アイコンと App スイッチャーには出さない -->
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "built: $APP"
