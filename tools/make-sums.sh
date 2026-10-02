#!/bin/bash
# Regenerate SHA256SUMS for the root-installed payload. Run before every commit that
# touches a payload file, then publish the printed digest with the release.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# Single source of truth: the PAYLOAD array in setup.sh.
mapfile -t files < <(sed -n '/^PAYLOAD=(/,/^)/p' setup.sh | sed '1d;$d' | awk '{print $1}')
sha256sum "${files[@]}" >SHA256SUMS
echo "SHA256SUMS digest: $(sha256sum SHA256SUMS | awk '{print $1}')"
