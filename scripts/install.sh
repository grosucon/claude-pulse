#!/bin/bash
# Build Claude Pulse and install it as a real .app bundle under
# ~/Applications/. The bundle is the only form Spotlight will index;
# the raw SPM binary at .build/release/ClaudePulse will not show up.
#
# Re-run this script whenever you change the source -- it overwrites
# the installed bundle in place and relaunches.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Claude Pulse"
BUNDLE_ID="com.grosucon.claude-pulse"
INSTALL_ROOT="$HOME/Applications"
APP_PATH="$INSTALL_ROOT/$APP_NAME.app"
EXEC_NAME="ClaudePulse"

cd "$PROJECT_ROOT"

echo "==> Building release binary..."
swift build -c release --product "$EXEC_NAME"
BIN_DIR="$(swift build -c release --product "$EXEC_NAME" --show-bin-path)"
BINARY_PATH="$BIN_DIR/$EXEC_NAME"

if [ ! -x "$BINARY_PATH" ]; then
  echo "Build did not produce an executable at: $BINARY_PATH" >&2
  exit 1
fi

VERSION="$(date +%Y.%m.%d)"

echo "==> Stopping any running instance..."
pkill -f "$APP_PATH/Contents/MacOS/$EXEC_NAME" 2>/dev/null || true
pkill -f ".build/release/$EXEC_NAME"           2>/dev/null || true

echo "==> Constructing bundle at $APP_PATH"
mkdir -p "$INSTALL_ROOT"
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"

cp "$BINARY_PATH" "$APP_PATH/Contents/MacOS/$EXEC_NAME"
chmod +x "$APP_PATH/Contents/MacOS/$EXEC_NAME"

echo "==> Generating app icon..."
ICONSET_DIR="$(mktemp -d)/AppIcon.iconset"
swift "$PROJECT_ROOT/scripts/generate-icon.swift" "$ICONSET_DIR"
iconutil --convert icns "$ICONSET_DIR" --output "$APP_PATH/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET_DIR")"

cat > "$APP_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>           <string>en</string>
    <key>CFBundleDisplayName</key>                 <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>                  <string>$EXEC_NAME</string>
    <key>CFBundleIconFile</key>                    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>                  <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>       <string>6.0</string>
    <key>CFBundleName</key>                        <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>                 <string>APPL</string>
    <key>CFBundleShortVersionString</key>          <string>$VERSION</string>
    <key>CFBundleVersion</key>                     <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>              <string>14.0</string>
    <key>LSUIElement</key>                         <true/>
    <key>NSHumanReadableCopyright</key>            <string>Claude Pulse</string>
    <key>NSSupportsAutomaticTermination</key>      <true/>
    <key>NSSupportsSuddenTermination</key>         <true/>
</dict>
</plist>
PLIST

echo "==> Registering with Launch Services so Spotlight indexes it..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$APP_PATH" >/dev/null 2>&1 || true

echo "==> Launching..."
open "$APP_PATH"

cat <<EOF

Installed: $APP_PATH
  Spotlight: Cmd-Space, type "Claude Pulse"
  Finder:    ~/Applications -> Claude Pulse

To start on every login:
  System Settings -> General -> Login Items & Extensions
  Under "Open at Login", click + and add:
    $APP_PATH

Or one-shot from the terminal:
  osascript -e 'tell application "System Events" to make login item at end with properties {path:"$APP_PATH", hidden:false}'

EOF
