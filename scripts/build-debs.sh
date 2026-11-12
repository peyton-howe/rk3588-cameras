#!/usr/bin/env bash
# Build the architecture-independent packages (rk3588-camera-dkms and
# rk3588-camera-overlays) into build/debs/. The libcamera packages are built
# separately, on the Ubuntu release they are for: see libcamera/build.sh.
set -eE
trap 'echo Error: in $0 on line $LINENO' ERR

cd "$(dirname -- "$(readlink -f -- "$0")")/.."
REPO_ROOT="$(pwd)"
OUT_DIR="${REPO_ROOT}/build/debs"
mkdir -p "${OUT_DIR}"

for tool in dpkg-buildpackage dtc gcc python3; do
    command -v "${tool}" >/dev/null || { echo "Error: missing ${tool}"; exit 1; }
done
dpkg -s debhelper >/dev/null 2>&1 || {
    echo "Error: debhelper not installed (apt install debhelper dh-dkms device-tree-compiler dpkg-dev)"
    exit 1
}

# directory:package
PACKAGES=(
    "overlays:rk3588-camera-overlays"
    "dkms:rk3588-camera-dkms"
)

for entry in "${PACKAGES[@]}"; do
    dir="${entry%%:*}"
    name="${entry#*:}"
    echo "[+] Building ${name}..."
    (
        cd "${REPO_ROOT}/${dir}"
        rm -rf "debian/${name}" debian/.debhelper debian/files debian/*.substvars debian/*.debhelper.log 2>/dev/null || true
        dpkg-buildpackage -us -uc -b
    )
    # Drop older versions so a consumer that globs ${name}_*.deb gets one.
    rm -f "${OUT_DIR}/${name}_"*.deb "${OUT_DIR}/${name}_"*.buildinfo "${OUT_DIR}/${name}_"*.changes
    mv -v "${REPO_ROOT}/${name}_"*.deb "${REPO_ROOT}/${name}_"*.buildinfo "${REPO_ROOT}/${name}_"*.changes "${OUT_DIR}/"
done

echo "[+] Packages in ${OUT_DIR}:"
ls -la "${OUT_DIR}"/*.deb
