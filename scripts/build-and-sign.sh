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
# Usage:
#   ./scripts/build-and-sign.sh            # release build, signed
#   ./scripts/build-and-sign.sh --run      # build, sign, then launch
#
set -euo pipefail

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

# 2. Build a release binary.
echo "› Building release…"
swift build -c release

BINARY="$ROOT/.build/release/usage-touchbar"

# 3. Sign it with the stable identity + a fixed bundle identifier.
echo "› Signing…"
IDENTITY_SHA1="$(
    security find-certificate -a -c "$IDENTITY_NAME" -Z "$KEYCHAIN" \
        | awk '/SHA-1 hash:/ && !seen { print $3; seen=1 }'
)"

if [[ -z "$IDENTITY_SHA1" ]]; then
    echo "Could not resolve signing identity '$IDENTITY_NAME'." >&2
    exit 1
fi

codesign --force --options runtime \
    --identifier "$BUNDLE_ID" \
    --sign "$IDENTITY_SHA1" \
    "$BINARY"

codesign --verify --verbose "$BINARY" >/dev/null 2>&1 && echo "  signature OK."

# 3b. Produce the two provider-agent binaries. They are copies of the same build
#     signed with DISTINCT bundle identifiers so the system treats them as
#     separate apps — the launcher (main binary) spawns these to get one Control
#     Strip slot each.
for AGENT in codex claude; do
    AGENT_BINARY="$ROOT/.build/release/usage-touchbar-$AGENT"
    cp -f "$BINARY" "$AGENT_BINARY"
    codesign --force --options runtime \
        --identifier "$BUNDLE_ID.$AGENT" \
        --sign "$IDENTITY_SHA1" \
        "$AGENT_BINARY"
    codesign --verify "$AGENT_BINARY" >/dev/null 2>&1 && echo "  $AGENT agent signed ($BUNDLE_ID.$AGENT)."
done

echo "✓ Built and signed: $BINARY"
echo "  On first launch, click \"Always Allow\" on the Keychain prompt(s) once —"
echo "  it will not ask again."

if [[ "${1:-}" == "--run" ]]; then
    echo "› Launching…"
    exec "$BINARY"
fi
