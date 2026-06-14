#!/usr/bin/env bash
# Creates a stable, self-signed code-signing identity ("Jarvis Dev") in the login keychain so that
# macOS TCC permission grants (Microphone, Screen Recording) persist across rebuilds. Ad-hoc signing
# changes the app's identity every build, which makes macOS forget permissions and re-prompt.
#
# Run once. Safe to re-run (it will create a second identity; delete extras in Keychain Access if so).
# The identity is untrusted (self-signed) — that's fine for local signing; it just needs to be stable.
set -euo pipefail

NAME="Jarvis Dev"
if security find-identity -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "✅ '$NAME' identity already exists."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/csr.conf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $NAME
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -nodes -config "$TMP/csr.conf" >/dev/null 2>&1

# Legacy PBE/MAC so macOS `security` can import the PKCS#12 (OpenSSL 3 default is incompatible).
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" \
  -name "$NAME" -passout pass:jarvis \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 >/dev/null 2>&1

# Least privilege: scope key access to /usr/bin/codesign only (NOT -A, which would let any app
# use the signing key). The first build triggers a one-time keychain prompt — click "Always Allow".
security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P jarvis -T /usr/bin/codesign

echo "✅ created '$NAME' (codesign-scoped)."
echo "   On the next build, macOS will ask once to let codesign use the key — click 'Always Allow'."
echo "   Then grant Microphone/Screen Recording once more; they persist across rebuilds afterward."
