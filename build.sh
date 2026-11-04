#!/bin/zsh
# Builds Island.app and installs it to /Applications.
set -e
cd "$(dirname "$0")"

app=Island.app
rm -rf $app
mkdir -p $app/Contents/MacOS $app/Contents/Resources
swiftc -O Island.swift -o $app/Contents/MacOS/Island
cp claude.gif $app/Contents/Resources/

cat > $app/Contents/Info.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Island</string>
    <key>CFBundleDisplayName</key><string>Island</string>
    <key>CFBundleIdentifier</key><string>com.ayaansajjad.island</string>
    <key>CFBundleExecutable</key><string>Island</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.2</string>
    <key>LSUIElement</key><true/>
    <key>NSAudioCaptureUsageDescription</key><string>Island listens to Music so the bars move with the song.</string>
    <key>NSAppleEventsUsageDescription</key><string>Island reads the current track from Music.</string>
</dict>
</plist>
EOF

codesign --force --sign - $app

rm -rf /Applications/$app ~/Applications/$app
mv $app /Applications/
echo "Installed /Applications/$app"
