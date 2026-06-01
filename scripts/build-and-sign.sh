#!/usr/bin/env bash
#
# Builds Usage Touch Bar and signs it with a STABLE self-signed code-signing
# identity. This is what stops macOS from re-asking for your login password to
# read Claude's Keychain token on every rebuild.
#
# Why this is needed:
#   When you click "Always Allow" on the Keychain prompt, macOS remembers the
#   *exact* binary that asked. An unsigned binary is identified by its content
#   hash, which changes on every `swift build`, so the grant is forgotten and you
#   get prompted again. Signing every build with the same identity gives the app
#   a stable identity, so "Always Allow" sticks permanently.
#
# The binary is built as a UNIVERSAL (fat) Mach-O containing both arm64 and
# x86_64 slices, so the same UsageTouchBar.app runs on Apple Silicon (M-series
# 13" MacBook Pro with Touch Bar) AND Intel Macs (2016-2019 MacBook Pro with
# Touch Bar).
#
# Usage:
#   ./scripts/build-and-sign.sh            # universal release build, signed, installed
#   ./scripts/build-and-sign.sh --run      # …and (re)launch it
#   ./scripts/build-and-sign.sh --dmg      # …and also produce a distributable .dmg
#
# Flags can be combined, e.g. `./scripts/build-and-sign.sh --run --dmg`.
#
set -euo pipefail

WANT_RUN=0
WANT_DMG=0
for arg in "$@"; do
    case "$arg" in
        --run) WANT_RUN=1 ;;
        --dmg) WANT_DMG=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

IDENTITY_NAME="UsageTouchBar Local Signing"
BUNDLE_ID="com.neelashkannan.usage-touchbar"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 1. Create a reusable self-signed code-signing identity the first time only.
if ! security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -F "$IDENTITY_NAME" >/dev/null; then
    echo "› Creating self-signed code-signing identity '$IDENTITY_NAME' (one-time)…"
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT

    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 \
        -subj "/CN=$IDENTITY_NAME" \
        -addext "extendedKeyUsage=codeSigning" \
        -addext "keyUsage=critical,digitalSignature" >/dev/null 2>&1

    # Export the .p12 with the system LibreSSL (/usr/bin/openssl): it writes a
    # SHA1-MAC PKCS#12 that macOS's importer accepts. OpenSSL 3.x's default MAC
    # (and even -legacy) is rejected by SecurityFramework with a MAC error.
    # A non-empty passphrase avoids `security import`'s empty-password MAC bug.
    P12_PASS="usagetouchbar"
    /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
        -out "$TMP/identity.p12" -passout "pass:$P12_PASS" >/dev/null 2>&1

    # -T /usr/bin/codesign lets codesign use the private key without prompting.
    security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$P12_PASS" \
        -T /usr/bin/codesign >/dev/null

    # Allow codesign to read the key non-interactively in future runs.
    security set-key-partition-list -S apple-tool:,apple: -k "" "$KEYCHAIN" >/dev/null 2>&1 || true
    echo "  done."
fi

# 2. Build a UNIVERSAL release binary (arm64 + x86_64) so one app runs on both
#    Apple Silicon and Intel Touch Bar Macs.
echo "› Building universal release (arm64 + x86_64)…"
swift build -c release --arch arm64 --arch x86_64

BINARY="$ROOT/.build/apple/Products/Release/usage-touchbar"
if [[ ! -f "$BINARY" ]]; then
    echo "Universal binary not found at $BINARY" >&2
    exit 1
fi
echo "  architectures: $(lipo -archs "$BINARY")"

# 3. Resolve the stable signing identity.
IDENTITY_SHA1="$(
    security find-certificate -a -c "$IDENTITY_NAME" -Z "$KEYCHAIN" \
        | awk '/SHA-1 hash:/ && !seen { print $3; seen=1 }'
)"

if [[ -z "$IDENTITY_SHA1" ]]; then
    echo "Could not resolve signing identity '$IDENTITY_NAME'." >&2
    exit 1
fi

# 4. Assemble ONE app bundle. A single bundle (one identity, one bundle id)
#    means exactly one Keychain "Always Allow" grant — no more repeat prompts.
APP="$ROOT/UsageTouchBar.app"
echo "› Building app bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -f "$BINARY" "$APP/Contents/MacOS/usage-touchbar"
cp -f "$ROOT/Info.plist" "$APP/Contents/Info.plist"

# 5. Sign the bundle with the stable identity + fixed bundle identifier.
echo "› Signing…"
codesign --force --options runtime \
    --identifier "$BUNDLE_ID" \
    --sign "$IDENTITY_SHA1" \
    "$APP/Contents/MacOS/usage-touchbar"
codesign --force --options runtime \
    --identifier "$BUNDLE_ID" \
    --sign "$IDENTITY_SHA1" \
    "$APP"
codesign --verify --verbose "$APP" >/dev/null 2>&1 && echo "  signature OK."

# 6. Strip the quarantine flag so Gatekeeper doesn't nag.
xattr -cr "$APP" 2>/dev/null || true

# 7. Install to ~/Applications (user space → no admin password).
INSTALL_DIR="$HOME/Applications"
INSTALLED_APP="$INSTALL_DIR/UsageTouchBar.app"
INSTALLED_BIN="$INSTALLED_APP/Contents/MacOS/usage-touchbar"
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALLED_APP"
cp -R "$APP" "$INSTALL_DIR/"
xattr -cr "$INSTALLED_APP" 2>/dev/null || true

# 8. Install/refresh the LaunchAgent so exactly ONE instance runs, points at the
#    SIGNED installed app (never the dev build), and relaunches at login.
LABEL="com.neelashkannan.usage-touchbar"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$INSTALLED_BIN</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>LegacyTimeout</key>
    <string>30</string>
</dict>
</plist>
PLIST_EOF

# Reload: stop the old job, kill any stragglers, start the single managed copy.
launchctl unload "$PLIST" 2>/dev/null || true
pkill -f "usage-touchbar" 2>/dev/null || true
sleep 1
launchctl load "$PLIST" 2>/dev/null || true

echo "✓ Built, signed, installed, and (re)launched: $INSTALLED_APP"
echo "  On first launch, click \"Always Allow\" on the Keychain prompt ONCE —"
echo "  with the stable signature it will not ask again."
echo "  Arrange/hide providers from the gear on the expanded Touch Bar,"
echo "  or in ~/.config/usage-touchbar/config.json"

# 9. Optionally package a distributable disk image. The DMG contains the signed
#    universal app plus an /Applications symlink so anyone can drag-to-install
#    on either Intel or Apple Silicon Touch Bar Macs.
if [[ "$WANT_DMG" == "1" ]]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo "1.0.0")"
    DIST_DIR="$ROOT/dist"
    DMG_PATH="$DIST_DIR/UsageTouchBar-$VERSION.dmg"
    STAGING="$(mktemp -d)"
    trap 'rm -rf "$STAGING"' EXIT

    echo "› Packaging DMG…"
    mkdir -p "$DIST_DIR"
    cp -R "$APP" "$STAGING/UsageTouchBar.app"
    ln -s /Applications "$STAGING/Applications"
    rm -f "$DMG_PATH"
    hdiutil create \
        -volname "Usage Touch Bar" \
        -srcfolder "$STAGING" \
        -ov -format UDZO \
        "$DMG_PATH" >/dev/null
    # Sign the disk image itself with the same stable identity.
    codesign --force --sign "$IDENTITY_SHA1" "$DMG_PATH" >/dev/null 2>&1 || true
    echo "✓ Disk image ready: $DMG_PATH"
fi

if [[ "$WANT_RUN" == "1" ]]; then
    echo "› Already launched by launchd (KeepAlive)."
fi
