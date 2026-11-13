#!/bin/sh
# Make FrostByte's release-signing key pair (Ed25519). Run it once, ever; the app trusts one key.
#   tools/make-release-key.sh [private-key.pem]
# The private key goes to ~/.config/frostbyte-release/ed25519-private.pem (mode 600) unless a path is given.
# Keep it outside every repository and back it up offline: losing it means no signed updates for copies
# already out there. The script prints only the PUBLIC key (hex, 32 bytes), which belongs in
# kUpdatePublicKey in frostbyte/shell/fb-update.m; it also lands beside the private key as ed25519-public.hex.
# Needs OpenSSL 1.1.1 or later (Ed25519).
# Copyright (c) 2026 Jordan Bettcher
# SPDX-License-Identifier: MIT
set -e
KEY="${1:-$HOME/.config/frostbyte-release/ed25519-private.pem}"
if [ -e "$KEY" ]; then
    echo "$KEY already exists; not replacing a release key" >&2
    exit 1
fi
umask 077
mkdir -p "$(dirname "$KEY")"
openssl genpkey -algorithm ed25519 -out "$KEY"
chmod 600 "$KEY"
# The DER SubjectPublicKeyInfo of an Ed25519 key ends with the 32 raw key bytes.
PUB=$(openssl pkey -in "$KEY" -pubout -outform DER | tail -c 32 | od -An -v -tx1 | tr -d ' \n')
[ ${#PUB} -eq 64 ] || { echo "unexpected public key: $PUB" >&2; exit 1; }
printf '%s\n' "$PUB" > "$(dirname "$KEY")/ed25519-public.hex"
echo "private key: $KEY (mode 600). Back it up offline; never commit or copy it into a tree."
echo "public key:  $PUB"
