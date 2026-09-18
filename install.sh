#!/bin/bash
# Builds meter, packages it as a menu bar app bundle, and installs a LaunchAgent.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

# Sign with a stable self-signed identity. Ad-hoc (linker-signed) binaries get a
# new hash every build, which invalidates keychain ACLs and re-triggers
# SecurityAgent password prompts for the Claude/Zed credentials meter reads.
IDENTITY="meter codesign"
if ! security find-certificate -c "$IDENTITY" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1; then
    tmp="$(mktemp -d)"
    openssl req -x509 -newkey rsa:2048 -keyout "$tmp/key" -out "$tmp/crt" \
        -days 7300 -nodes -subj "/CN=$IDENTITY" \
        -addext "keyUsage=digitalSignature" -addext "extendedKeyUsage=codeSigning" 2>/dev/null
    openssl pkcs12 -export -out "$tmp/cert.p12" -inkey "$tmp/key" -in "$tmp/crt" \
        -passout pass:meter -name "$IDENTITY" -macalg sha1 \
        -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES 2>/dev/null
    security import "$tmp/cert.p12" -k ~/Library/Keychains/login.keychain-db \
        -P meter -T /usr/bin/codesign
    rm -rf "$tmp"
fi

# A real bundle: LSUIElement keeps it out of the Dock, gives notifications and
# login-item management a stable identity, and reserves space for widgets.
APP="$HOME/Applications/meter.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp -f .build/release/meter "$APP/Contents/MacOS/meter"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>meter</string>
    <key>CFBundleIdentifier</key><string>app.meter.meter</string>
    <key>CFBundleName</key><string>meter</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# -i keeps the signing identifier stable ("meter"), so keychain grants made
# before the bundle existed keep matching.
codesign --force --sign "$IDENTITY" -i meter "$APP"

# `meter --print` / --json / --dashboard from a shell
BIN="$HOME/.local/bin/meter"
mkdir -p "$HOME/.local/bin"
ln -sf "$APP/Contents/MacOS/meter" "$BIN"

PLIST="$HOME/Library/LaunchAgents/app.meter.meter.plist"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>app.meter.meter</string>
    <key>ProgramArguments</key>
    <array><string>$APP/Contents/MacOS/meter</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
</dict>
</plist>
EOF

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
echo "meter installed: $APP (agent: app.meter.meter)"
echo "menu bar item should appear now; config at ~/.config/meter/config.json"
