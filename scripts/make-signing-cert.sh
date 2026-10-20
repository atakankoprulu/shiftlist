#!/bin/bash
# One-time: creates a self-signed "Shiftlist Local Signing" certificate in your login keychain.
# Builds signed with it keep the same identity, so macOS remembers Accessibility/Finder permissions.
set -euo pipefail
NAME="Shiftlist Local Signing"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then echo "Zaten var: $NAME"; exit 0; fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cfg.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CNF
openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 -nodes -config "$TMP/cfg.cnf" 2>/dev/null
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:shiftlist -name "$NAME"
security import "$TMP/id.p12" -k ~/Library/Keychains/login.keychain-db -P shiftlist -T /usr/bin/codesign
echo "Oluşturuldu: $NAME"
