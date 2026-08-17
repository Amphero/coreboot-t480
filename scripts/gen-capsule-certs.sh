#!/usr/bin/env sh
# SPDX-License-Identifier: GPL-3.0-only
# gen-capsule-certs.sh - generate the capsule signing certificates into
# keys/capsule/.
#
#   sh scripts/gen-capsule-certs.sh
#
# Produces the three-level chain EDK2's PKCS7 verification expects
# (BaseTools/Source/Python/Pkcs7Sign/Readme.md): a root CA, an intermediate
# CA and a signing certificate. The firmware only embeds the root
# (CONFIG_DRIVERS_EFI_CAPSULE_TRUSTED_PUBLIC_CERT in config/defconfig);
# scripts/make-capsule.py signs with the other two. keys/capsule/ is
# untracked like the rest of keys/; without root.key you cannot re-issue a
# signer, without signer.pem you cannot sign a capsule this firmware accepts.
#
# RSA 4096 to match the vboot keyset, SHA256 because that is what
# FmpAuthenticationLibPkcs7 verifies. 30 years validity: the firmware checks
# the chain against the RTC, and an expired trust anchor would brick the
# update path, not the machine. Refuses to overwrite an existing set.
set -eu

PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$PROJECT/keys/capsule"
DAYS=10950

die() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

command -v openssl >/dev/null || die "openssl is missing"
[ -e "$DIR/root.key" ] && die "keys/capsule/ already holds a certificate set - move it away first"
mkdir -p "$DIR"
cd "$DIR"

EXT="$(mktemp)"
trap 'rm -f "$EXT" ./*.csr ./*.srl' EXIT
cat > "$EXT" <<'EOF'
[ ca ]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, cRLSign, keyCertSign
[ signer ]
basicConstraints = CA:FALSE
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
keyUsage = critical, digitalSignature
EOF

# Root CA - the trust anchor the firmware embeds.
openssl genrsa -out root.key 4096 2>/dev/null
openssl req -new -x509 -days "$DAYS" -sha256 -key root.key \
	-subj "/CN=custom-coreboot-t480 capsule root" \
	-extensions ca -config "$EXT" -out root.pub.pem

# Intermediate CA.
openssl genrsa -out sub.key 4096 2>/dev/null
openssl req -new -sha256 -key sub.key \
	-subj "/CN=custom-coreboot-t480 capsule sub" -out sub.csr
openssl x509 -req -days "$DAYS" -sha256 -in sub.csr \
	-CA root.pub.pem -CAkey root.key -CAcreateserial \
	-extfile "$EXT" -extensions ca -out sub.pub.pem 2>/dev/null

# Signing certificate. signer.pem carries certificate plus key in one file,
# the form GenerateCapsule.py --signer-private-cert wants.
openssl genrsa -out signer.key 4096 2>/dev/null
openssl req -new -sha256 -key signer.key \
	-subj "/CN=custom-coreboot-t480 capsule signer" -out signer.csr
openssl x509 -req -days "$DAYS" -sha256 -in signer.csr \
	-CA sub.pub.pem -CAkey sub.key -CAcreateserial \
	-extfile "$EXT" -extensions signer -out signer.pub.pem 2>/dev/null
cat signer.pub.pem signer.key > signer.pem

# Prove the chain signs and verifies the way the firmware will check it.
echo test > "$DIR/.selftest"
openssl smime -sign -binary -signer signer.pem -outform DER -md sha256 \
	-certfile sub.pub.pem -in "$DIR/.selftest" -out "$DIR/.selftest.p7"
openssl smime -verify -inform DER -in "$DIR/.selftest.p7" \
	-content "$DIR/.selftest" -CAfile root.pub.pem -out /dev/null 2>/dev/null \
	|| die "self-test failed: the chain does not verify against its own root"
rm -f "$DIR/.selftest" "$DIR/.selftest.p7"

chmod 600 root.key sub.key signer.key signer.pem
echo "keys/capsule/: root, sub and signer generated, chain self-test passed."
echo "The firmware picks up root.pub.pem via config/defconfig on the next build."
