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

# Release notes are author-controlled Markdown rendered to HTML upstream. CDATA keeps that HTML out
# of the XML grammar; the one sequence that could close the section early is stripped first.
DESCRIPTION=""
if [[ -n "$NOTES_HTML" ]]; then
  if [[ ! -f "$NOTES_HTML" || -L "$NOTES_HTML" ]]; then
    echo "error: release notes must be a regular file" >&2
    exit 1
  fi
  DESCRIPTION="$(/usr/bin/sed 's/]]>//g' "$NOTES_HTML")"
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

# Prove the recorded signature actually validates against the disk image users will download,
# before the feed can be published.
printf '%s' "$SPARKLE_ED_PRIVATE_KEY" \
  | "$SIGN_UPDATE" --ed-key-file - --verify "$DMG" "$SIGNATURE"
/usr/bin/xmllint --noout "$APPCAST"
echo "✅ $APPCAST describes Jarvis $SHORT_VERSION ($LENGTH bytes)"
