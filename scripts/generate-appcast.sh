#!/usr/bin/env bash
# Render the Sparkle appcast for a finished release disk image.
# Usage:  ./scripts/generate-appcast.sh Jarvis.dmg v0.1.8 [release-notes.html]
#
# Run only after package-app.sh staples the DMG: stapling rewrites it, and the EdDSA signature must
# cover the final bytes. SPARKLE_ED_PRIVATE_KEY goes to tools on stdin, never as an argument, so it
# stays out of the process list.
set -euo pipefail
cd "$(dirname "$0")/.."

DMG="${1:-}"
TAG="${2:-}"
NOTES_HTML="${3:-}"
APPCAST="appcast.xml"

if [[ $# -lt 2 || $# -gt 3 || -z "$DMG" || ! -f "$DMG" || -L "$DMG" ]]; then
  echo "usage: $0 Jarvis.dmg v<version> [release-notes.html]" >&2
  exit 2
fi
if [[ "$(basename "$DMG")" != "Jarvis.dmg" ]]; then
  echo "error: the appcast enclosure must be the released Jarvis.dmg" >&2
  exit 1
fi
if [[ -z "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
  echo "error: SPARKLE_ED_PRIVATE_KEY is required to sign the update" >&2
  exit 1
fi

# From the same SwiftPM artifact the app links, so tool and framework versions can't drift.
SIGN_UPDATE=".build/artifacts/sparkle/Sparkle/bin/sign_update"
if [[ ! -x "$SIGN_UPDATE" ]]; then
  echo "error: Sparkle's sign_update tool is missing; run swift build first" >&2
  exit 1
fi

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" Resources/Info.plist
}
VERSION="$(plist_value CFBundleVersion)"
SHORT_VERSION="$(plist_value CFBundleShortVersionString)"
MINIMUM_SYSTEM="$(plist_value LSMinimumSystemVersion)"

# Sign-then-verify with one key passes for any keypair, so compare the derived public key with the
# one installed copies trust. Sparkle exports a 32-byte Ed25519 seed, so the public half is derived.
DERIVED_PUBLIC_KEY="$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | /usr/bin/swift -e '
import CryptoKit
import Foundation
let seed = FileHandle.standardInput.readDataToEndOfFile()
let trimmed = String(decoding: seed, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
guard let raw = Data(base64Encoded: trimmed),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { exit(1) }
print(key.publicKey.rawRepresentation.base64EncodedString())
')"
if [[ "$DERIVED_PUBLIC_KEY" != "$(plist_value SUPublicEDKey)" ]]; then
  echo "error: SPARKLE_ED_PRIVATE_KEY does not match SUPublicEDKey in Resources/Info.plist;" >&2
  echo "       publishing this feed would make every installed copy reject the update." >&2
  exit 1
fi

if [[ "$TAG" != "v$SHORT_VERSION" ]]; then
  echo "error: release tag $TAG does not match bundled version $SHORT_VERSION" >&2
  exit 1
fi

# Pinned to the tag, not /releases/latest/, so the item keeps matching the bytes it signed.
REPOSITORY="${GITHUB_REPOSITORY:-JINGBANZ/jarvis}"
SERVER_URL="${GITHUB_SERVER_URL:-https://github.com}"
ENCLOSURE_URL="$SERVER_URL/$REPOSITORY/releases/download/$TAG/Jarvis.dmg"

LENGTH="$(/usr/bin/stat -f%z "$DMG")"
SIGNATURE="$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - -p "$DMG")"
if [[ -z "$SIGNATURE" ]]; then
  echo "error: sign_update produced no EdDSA signature" >&2
  exit 1
fi
PUB_DATE="$(/bin/date -u '+%a, %d %b %Y %H:%M:%S +0000')"

# Release notes are untrusted HTML inside CDATA. Split `]]>` across two sections instead of deleting
# it: a single-pass strip re-forms the terminator from `]]]]>>`.
DESCRIPTION=""
if [[ -n "$NOTES_HTML" ]]; then
  if [[ ! -f "$NOTES_HTML" || -L "$NOTES_HTML" ]]; then
    echo "error: release notes must be a regular file" >&2
    exit 1
  fi
  DESCRIPTION="$(/usr/bin/sed 's/]]>/]]]]><![CDATA[>/g' "$NOTES_HTML")"
fi

rm -f "$APPCAST"
{
  cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Jarvis</title>
    <description>Jarvis release updates.</description>
    <language>en</language>
    <item>
      <title>Version $SHORT_VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$SHORT_VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINIMUM_SYSTEM</sparkle:minimumSystemVersion>
XML
  if [[ -n "$DESCRIPTION" ]]; then
    printf '      <description><![CDATA[%s]]></description>\n' "$DESCRIPTION"
  fi
  cat <<XML
      <enclosure url="$ENCLOSURE_URL" length="$LENGTH" type="application/octet-stream" sparkle:edSignature="$SIGNATURE" />
    </item>
  </channel>
</rss>
XML
} > "$APPCAST"

# A description that escaped its CDATA section shows up here as invalid XML.
/usr/bin/xmllint --noout "$APPCAST"
echo "✅ $APPCAST describes Jarvis $SHORT_VERSION ($LENGTH bytes)"
