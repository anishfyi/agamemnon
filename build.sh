#!/usr/bin/env bash
# Build Agamemnon.app from the Swift package.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"
PRODUCT_DIR="$ROOT/.build/$CONFIG"
APP_DIR="$ROOT/Agamemnon.app"

echo "==> Running tests"
swift build -c debug --product AgamemnonTests
TEST_BIN="$(find "$ROOT/.build" -type f -name AgamemnonTests -path '*/debug/*' | head -n1)"
if [[ -z "$TEST_BIN" || ! -x "$TEST_BIN" ]]; then
  echo "error: AgamemnonTests binary not found" >&2
  exit 1
fi
"$TEST_BIN"

echo "==> Building Agamemnon ($CONFIG)"
swift build -c "$CONFIG" --product Agamemnon

BIN="$PRODUCT_DIR/Agamemnon"
if [[ ! -x "$BIN" ]]; then
  BIN="$(find "$ROOT/.build" -type f -name Agamemnon -path "*/$CONFIG/*" | head -n1)"
fi
if [[ -z "${BIN}" || ! -x "$BIN" ]]; then
  echo "error: Agamemnon binary not found after build" >&2
  exit 1
fi

echo "==> Assembling Agamemnon.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp "$BIN" "$APP_DIR/Contents/MacOS/Agamemnon"
chmod +x "$APP_DIR/Contents/MacOS/Agamemnon"

BIN_DIR="$(dirname "$BIN")"
if [[ -d "$BIN_DIR" ]]; then
  find "$BIN_DIR" -maxdepth 1 \( -name '*.dylib' -o -name '*.so' \) -exec cp {} "$APP_DIR/Contents/MacOS/" \; 2>/dev/null || true
fi

if [[ -d "$ROOT/assets" ]]; then
  cp -R "$ROOT/assets" "$APP_DIR/Contents/Resources/"
fi

# Finder, the Dock's app switcher and notification banners all read the icon from an
# .icns referenced by CFBundleIconFile. Without one macOS falls back to the blank
# generic-application icon, which is why Agamemnon showed up unbranded.
LOGO=""
for candidate in "$ROOT/Sources/Agamemnon/Resources/agamemnon.png" \
                 "$ROOT/assets/agamemnon-logo.png" \
                 "$ROOT/assets/agamemnon.png"; do
  if [[ -f "$candidate" ]]; then LOGO="$candidate"; break; fi
done
if [[ -n "$LOGO" ]] && command -v iconutil >/dev/null 2>&1; then
  echo "==> Generating AppIcon.icns"
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  # iconutil requires this exact set of sizes and filenames; a missing entry makes it
  # reject the whole iconset.
  for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
              "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" \
              "512 icon_256x256@2x" "512 icon_512x512" "1024 icon_512x512@2x"; do
    set -- $spec
    sips -z "$1" "$1" "$LOGO" --out "$ICONSET/$2.png" >/dev/null 2>&1
  done
  if iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns" 2>/dev/null; then
    echo "    wrote Contents/Resources/AppIcon.icns"
  else
    echo "    warning: iconutil failed, app will use the generic icon" >&2
  fi
  rm -rf "$(dirname "$ICONSET")"
fi

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>Agamemnon</string>
  <key>CFBundleIdentifier</key>
  <string>com.anishfyi.agamemnon</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Agamemnon</string>
  <key>CFBundleDisplayName</key>
  <string>Agamemnon</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
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

echo -n 'APPL????' > "$APP_DIR/Contents/PkgInfo"

echo "==> Built $APP_DIR"
echo "    Run: open $APP_DIR"
echo "    If Gatekeeper blocks: xattr -cr $APP_DIR"
