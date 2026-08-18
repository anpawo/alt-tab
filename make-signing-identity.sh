#!/usr/bin/env bash
# Creates the self-signed certificate alt-tab signs itself with.
#
# Why this exists: macOS attaches an Accessibility grant to the app's *signing identity*. An
# ad-hoc signature (`codesign --sign -`) has no identity — its fingerprint is a hash of the
# binary — so every rebuild looks like a brand new application and the permission has to be
# granted again, from a System Settings pane that now lists two entries called "alt-tab".
#
# A certificate is a stable identity, so a rebuild keeps what was already granted. Run once.
set -euo pipefail

IDENTITY="Alt-tab Self-Signed"

if [[ "$(security find-identity -v -p codesigning || true)" == *"$IDENTITY"* ]]; then
	echo "==> \"$IDENTITY\" already exists — nothing to do."
	exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

cat > ext.cnf <<'CONFIG'
[req]
distinguished_name=dn
[dn]
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CONFIG

echo "==> Generating a code-signing certificate"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
	-keyout key.pem -out cert.pem -subj "/CN=$IDENTITY" \
	-extensions ext -config ext.cnf 2>/dev/null

# The modern OpenSSL default (AES-256 / PBES2) is rejected by SecKeychainItemImport, which
# still expects the legacy PKCS#12 encryption — hence the explicit old-school algorithms, and
# a password, since an empty one fails MAC verification outright.
openssl pkcs12 -export -out alt-tab.p12 -inkey key.pem -in cert.pem \
	-passout pass:alt-tab -name "$IDENTITY" \
	-certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 2>/dev/null

echo "==> Importing into your login keychain"
# -T /usr/bin/codesign pre-authorises codesign to use the private key, so builds do not stop on
# a "wants to access your keychain" dialog.
security import alt-tab.p12 -k "$KEYCHAIN" -P alt-tab -T /usr/bin/codesign -A >/dev/null

# User-domain trust only. It lets nothing new onto the machine: the certificate signs one app,
# locally, and is trusted for nothing else. Skipped rather than fatal if the prompt is declined —
# codesign only needs the identity, not the trust.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" cert.pem 2>/dev/null \
	|| echo "==> (not marked trusted — signing still works)"

security find-identity -v -p codesigning | grep "$IDENTITY"
echo
echo "Done. Rebuild with ./install.sh, approve Accessibility one final time, and it will"
echo "stick across every future build."
echo
echo "To undo: delete \"$IDENTITY\" in Keychain Access (login keychain, My Certificates)."
