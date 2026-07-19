#!/usr/bin/env bash
# Build Warden.app from the Swift package.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"
PRODUCT_DIR="$ROOT/.build/$CONFIG"
APP_DIR="$ROOT/Warden.app"

echo "==> Running tests"
swift build -c debug --product WardenTests
TEST_BIN="$(find "$ROOT/.build" -type f -name WardenTests -path '*/debug/*' | head -n1)"
if [[ -z "$TEST_BIN" || ! -x "$TEST_BIN" ]]; then
  echo "error: WardenTests binary not found" >&2
  exit 1
fi
"$TEST_BIN"

echo "==> Building Warden ($CONFIG)"
swift build -c "$CONFIG" --product Warden

BIN="$PRODUCT_DIR/Warden"
if [[ ! -x "$BIN" ]]; then
  # SwiftPM may nest under arch triples
  BIN="$(find "$ROOT/.build" -type f -name Warden -path "*/$CONFIG/*" | head -n1)"
fi
if [[ -z "${BIN}" || ! -x "$BIN" ]]; then
  echo "error: Warden binary not found after build" >&2
  exit 1
fi

echo "==> Assembling Warden.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp "$BIN" "$APP_DIR/Contents/MacOS/Warden"
chmod +x "$APP_DIR/Contents/MacOS/Warden"

# Copy linked dylibs / swift libs if present beside the binary
BIN_DIR="$(dirname "$BIN")"
if [[ -d "$BIN_DIR" ]]; then
  find "$BIN_DIR" -maxdepth 1 \( -name '*.dylib' -o -name '*.so' \) -exec cp {} "$APP_DIR/Contents/MacOS/" \; 2>/dev/null || true
fi

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>Warden</string>
  <key>CFBundleIdentifier</key>
  <string>local.warden.app</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Warden</string>
  <key>CFBundleDisplayName</key>
  <string>Warden</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSUserNotificationAlertStyle</key>
  <string>alert</string>
</dict>
</plist>
PLIST

# PkgInfo
echo -n 'APPL????' > "$APP_DIR/Contents/PkgInfo"

echo "==> Built $APP_DIR"
echo "    Run: open $APP_DIR"
echo "    If Gatekeeper blocks: xattr -cr $APP_DIR"
