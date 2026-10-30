#!/bin/bash
# Builds meter, packages it as a menu bar app bundle, and installs a LaunchAgent.
set -euo pipefail
cd "$(dirname "$0")"
# rustup installed with --no-modify-path, so cargo is not on the default PATH
export PATH="$HOME/.cargo/bin:$PATH"

swift build -c release --package-path menubar

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
cp -f menubar/.build/release/meter "$APP/Contents/MacOS/meter"
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

# `meter --print` / --json from a shell
BIN="$HOME/.local/bin/meter"
mkdir -p "$HOME/.local/bin"
ln -sf "$APP/Contents/MacOS/meter" "$BIN"

# The collector is the only thing that scans this machine. Without a Rust
# toolchain the app still installs, but nothing will be collected locally.
if command -v cargo >/dev/null 2>&1; then
    cargo build --release --manifest-path collector/Cargo.toml
    cp -f collector/target/release/meter-collector "$HOME/.local/bin/meter-collector"
else
    echo "cargo not found: skipping the collector (install rustup to collect locally)" >&2
fi

ENV_FILE="$HOME/.config/meter/collector.env"
if [ ! -f "$ENV_FILE" ]; then
    mkdir -p "$(dirname "$ENV_FILE")"
    URL=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("collector",{}).get("url",""))' \
        "$HOME/.config/meter/config.json" 2>/dev/null || true)
    {
        echo "METER_URL=${URL}"
        echo "METER_HOST=mac"
        echo "METER_DAYS=30"
    } > "$ENV_FILE"
    chmod 600 "$ENV_FILE"
fi

PLIST="$HOME/Library/LaunchAgents/app.meter.menubar.plist"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>app.meter.menubar</string>
    <key>ProgramArguments</key>
    <array><string>$APP/Contents/MacOS/meter</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

COLLECTOR_PLIST="$HOME/Library/LaunchAgents/app.meter.collector.plist"
if [ -x "$HOME/.local/bin/meter-collector" ]; then
    cat > "$COLLECTOR_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>app.meter.collector</string>
    <key>ProgramArguments</key>
    <array><string>$HOME/.local/bin/meter-collector</string></array>
    <key>RunAtLoad</key><true/>
    <key>StartInterval</key><integer>600</integer>
    <key>ProcessType</key><string>Background</string>
    <key>StandardErrorPath</key><string>$HOME/.cache/meter/collector.log</string>
</dict>
</plist>
EOF
    mkdir -p "$HOME/.cache/meter"
    launchctl bootout "gui/$(id -u)" "$COLLECTOR_PLIST" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$COLLECTOR_PLIST"
fi
echo "meter installed: $APP (agent: app.meter.menubar, collector: app.meter.collector)"
echo "menu bar item should appear now; config at ~/.config/meter/config.json"
echo "collector config at ~/.config/meter/collector.env (METER_URL is required)"
