#!/bin/zsh
# Builds AirMouse.app (own bundle => own Bluetooth/Accessibility permission prompts), ad-hoc signed.
set -e
cd "$(dirname "$0")"
APP=build/AirMouse.app
mkdir -p $APP/Contents/MacOS logs
swiftc -O -o $APP/Contents/MacOS/AirMouse Sources/*.swift
cat > $APP/Contents/Info.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.airmouse.bridge</string>
  <key>CFBundleName</key><string>AirMouse</string>
  <key>CFBundleExecutable</key><string>AirMouse</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSUIElement</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key><string>AirMouse connects to your Amazfit watch to read motion and button events.</string>
</dict></plist>
EOF
# Ad-hoc signatures change their cdhash every build, and TCC (Accessibility) pins the grant to it,
# so pin the designated requirement to the bundle identifier instead: one grant survives rebuilds.
codesign --force --sign - -r='designated => identifier "local.airmouse.bridge"' $APP
echo "built $APP"
