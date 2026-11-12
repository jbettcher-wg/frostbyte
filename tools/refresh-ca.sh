#!/bin/sh
# Refresh the TLS trust data FrostByte ships (then rebuild: deps/build-deps.sh gnutls glibnetworking):
#   - cacert.pem: Mozilla's root store, as extracted by curl.se
#   - mozilla-intermediates.csv: Mozilla CCADB, non-revoked intermediates chaining to Mozilla roots,
#     used only to complete chains servers send incomplete (glib-networking patch 0002)
set -e
DL="$(cd "$(dirname "$0")/.." && pwd)/upstream/dl/deps"
curl -sSfL -o "$DL/cacert.pem.new" https://curl.se/ca/cacert.pem
curl -sSfL -o "$DL/mozilla-intermediates.csv.new" "https://ccadb.my.salesforce-sites.com/mozilla/MozillaIntermediateCertsCSVReport"
grep -q "BEGIN CERTIFICATE" "$DL/cacert.pem.new" && grep -q "BEGIN CERTIFICATE" "$DL/mozilla-intermediates.csv.new"
mv "$DL/cacert.pem.new" "$DL/cacert.pem"
mv "$DL/mozilla-intermediates.csv.new" "$DL/mozilla-intermediates.csv"
echo "roots: $(grep -c 'BEGIN CERTIFICATE' "$DL/cacert.pem")  intermediates: $(grep -c 'BEGIN CERTIFICATE' "$DL/mozilla-intermediates.csv")"
