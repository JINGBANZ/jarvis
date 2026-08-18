#!/usr/bin/env bash
# Render the Sparkle appcast for a finished release disk image.
#
# Sparkle's menu-bar update check reads this feed, compares its version with the running bundle, and
# verifies the downloaded disk image against the EdDSA signature recorded here. The signature must
# therefore be taken over the *final* artifact: stapling rewrites the file, so this runs after
# package-app.sh has notarized, stapled, and verified Jarvis.dmg — never before.
#
# Usage:  ./scripts/generate-appcast.sh Jarvis.dmg v0.1.8 [release-notes.html]
#
# Credentials:
#   SPARKLE_ED_PRIVATE_KEY — the EdDSA private key whose public half is SUPublicEDKey in
#     Resources/Info.plist. Generated once with Sparkle's generate_keys and held as a repository
#     secret in the release environment. Passed on standard input, never as an argument, so it
#     cannot appear in the process list.
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

# Sparkle ships its signing tools in the same SwiftPM artifact the app links against, so the release
# build has already fetched them and the versions cannot drift apart.
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

# Prove the signing key is the one installed copies verify against. Signing and then verifying with
# the same private key is self-referential: it passes for *any* valid keypair, so a rotated or
# mis-pasted secret would publish a feed that every client silently rejects until the next release.
# Sparkle exports a 32-byte Ed25519 seed, so the public half is derived rather than sliced off.
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

# The feed must describe the artifact the tag actually published, or Sparkle would offer an update
# that downloads different bytes than the release notes describe.
if [[ "$TAG" != "v$SHORT_VERSION" ]]; then
  echo "error: release tag $TAG does not match bundled version $SHORT_VERSION" >&2
  exit 1
fi

# Pin the enclosure to the tag rather than /releases/latest/, so this item keeps resolving to the
# exact disk image it was signed over even after later releases move "latest".
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

# Release notes are author-controlled Markdown rendered to HTML upstream, so the text can contain
# anything a commit subject can. CDATA keeps that HTML out of the XML grammar, and the one sequence
# that could close the section early is split across two CDATA sections rather than deleted: a
# single-pass strip re-forms the terminator from `]]]]>>` and would let content escape into markup.
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

# The signature covers the right bytes (checked above against the plist's public key), so the
# remaining risk is a malformed feed — a description that broke out of its CDATA section would show
# up here as invalid XML.
/usr/bin/xmllint --noout "$APPCAST"
echo "✅ $APPCAST describes Jarvis $SHORT_VERSION ($LENGTH bytes)"
