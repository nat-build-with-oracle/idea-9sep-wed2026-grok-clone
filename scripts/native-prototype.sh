#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE="$ROOT/Prototypes/NativeShell"
MODE="${1:-build}"
if [[ "$MODE" != "build" && "$MODE" != "run" && "$MODE" != "snapshot" && "$MODE" != "test" ]]; then
  echo "Usage: $0 [build|run|snapshot|test] [preview arguments]" >&2
  exit 2
fi
if [[ "$MODE" == "test" ]]; then exec swift test --package-path "$PACKAGE"; fi
swift build --package-path "$PACKAGE"
BIN="$(swift build --package-path "$PACKAGE" --show-bin-path)"
APP_NAME="NativeShellPrototype"
BUNDLE_ID="local.independent.NativeShellPrototype"
if [[ "${NATIVE_WORKSPACE_APP:-0}" == "1" ]]; then
  APP_NAME="BotWorkspace"
  BUNDLE_ID="local.independent.BotWorkspace"
fi
APP="$PACKAGE/.build/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/NativeShell" "$APP/Contents/MacOS/NativeShell"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>NativeShell</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>$APP_NAME</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
ENTITLEMENTS="$PACKAGE/.build/preview.entitlements"
NETWORK_ENTITLEMENT=""
FILE_ENTITLEMENT=""
if [[ "${NATIVE_WORKSPACE_APP:-0}" == "1" ]]; then
  NETWORK_ENTITLEMENT='<key>com.apple.security.network.client</key><true/>'
  FILE_ENTITLEMENT='<key>com.apple.security.files.user-selected.read-write</key><true/>'
fi
cat > "$ENTITLEMENTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/>$NETWORK_ENTITLEMENT$FILE_ENTITLEMENT</dict></plist>
PLIST
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --strict "$APP"
echo "App: $APP"
if [[ "$MODE" == "run" ]]; then
  shift
  open "$APP" --args "$@"
elif [[ "$MODE" == "snapshot" ]]; then
  if [[ "${NATIVE_WORKSPACE_APP:-0}" == "1" ]]; then
    echo "Snapshots are restricted to the sample prototype; use scripts/native-prototype.sh snapshot." >&2
    exit 2
  fi
  shift
  exec "$APP/Contents/MacOS/NativeShell" --snapshot "$@"
fi
