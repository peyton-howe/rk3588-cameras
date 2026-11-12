#!/usr/bin/env bash
# Collect the built .debs into one directory with a SHA256SUMS manifest, ready
# to upload as the assets of a release.
#
# Usage: make-release.sh <out dir> <deb dir>...
#   make-release.sh release build/debs build/libcamera/resolute
set -euo pipefail

out="${1:?output directory}"
shift
[[ $# -gt 0 ]] || { echo "Error: no deb directories given" >&2; exit 1; }

rm -rf "${out}"
mkdir -p "${out}"
for dir in "$@"; do
    cp -v "${dir}"/*.deb "${out}/"
done
(cd "${out}" && sha256sum -- *.deb > SHA256SUMS)
echo "[+] ${out}:"
cat "${out}/SHA256SUMS"
