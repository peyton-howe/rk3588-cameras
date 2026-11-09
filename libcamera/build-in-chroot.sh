#!/usr/bin/env bash
# Build the libcamera packages for an Ubuntu release in a throwaway chroot made
# from Ubuntu's own base image for that release, so the packages link against the
# libraries that release ships whatever host this runs on. It then installs the
# result inside the chroot and checks that libcamera loads.
#
# Usage: build-in-chroot.sh <release> [output dir]
#   release: resolute | stonking     (default output: build/libcamera/<release>)
# Needs root (it uses sudo if you are not), network access, and an arm64 host.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
die() { echo "Error: $*" >&2; exit 1; }

release="${1:?release (resolute, stonking)}"
OUT_DIR="${2:-${HERE}/../build/libcamera/${release}}"

# Ubuntu base image for each release: the final point release for a released
# series, the daily image for the development series.
case "${release}" in
    resolute) base_dir="https://cdimage.ubuntu.com/ubuntu-base/releases/26.04/release"
              base_file="ubuntu-base-26.04.1-base-arm64.tar.gz" ;;
    stonking) base_dir="https://cdimage.ubuntu.com/ubuntu-base/stonking/daily/current"
              base_file="stonking-base-arm64.tar.gz" ;;
    *) die "unsupported release '${release}' (resolute, stonking)" ;;
esac

[[ $(uname -m) == aarch64 ]] || die "this builds arm64 packages and needs an arm64 host"
if [[ ${EUID} -ne 0 ]]; then
    exec sudo -E "$0" "$@"
fi
for tool in curl tar chroot mount umount sha256sum findmnt; do
    command -v "${tool}" >/dev/null || die "missing ${tool}"
done

mkdir -p "${OUT_DIR}"
OUT_DIR="$(cd -- "${OUT_DIR}" && pwd)"

work="$(mktemp -d)"
root="${work}/root"

cleanup() {
    # Unmount everything under the chroot, deepest first, before deleting
    # anything: a bind mount left behind would have rm -rf reach the host.
    local m
    while read -r m; do
        umount -l "${m}" 2>/dev/null || true
    done < <(findmnt -rn -o TARGET | grep "^${work}/" | sort -r)
    if findmnt -rn -o TARGET | grep -q "^${work}/"; then
        echo "Warning: ${work} still has mounts; leaving it in place" >&2
        return
    fi
    rm -rf "${work}"
}
trap cleanup EXIT

echo "[+] Downloading ${base_file}"
curl -fsSL --retry 5 --retry-all-errors -o "${work}/${base_file}" "${base_dir}/${base_file}"
curl -fsSL --retry 5 --retry-all-errors -o "${work}/SHA256SUMS" "${base_dir}/SHA256SUMS"
(cd "${work}" && grep " \*\?${base_file}\$" SHA256SUMS | sha256sum -c --quiet -) \
    || die "${base_file} does not match the published SHA256SUMS"

echo "[+] Unpacking the base image"
mkdir -p "${root}"
tar -xpf "${work}/${base_file}" -C "${root}"

mkdir -p "${root}/proc" "${root}/sys" "${root}/dev" "${root}/cameras" "${root}/out"
# Make the rbind copies private so that unmounting them cannot propagate to the
# host's /dev and /sys.
mount -t proc proc "${root}/proc"
mount --rbind /sys "${root}/sys"
mount --make-rprivate "${root}/sys"
mount --rbind /dev "${root}/dev"
mount --make-rprivate "${root}/dev"
mount --bind "${HERE}" "${root}/cameras"
mount --make-private "${root}/cameras"
mount -o remount,bind,ro "${root}/cameras"
mount --bind "${OUT_DIR}" "${root}/out"
mount --make-private "${root}/out"
rm -f "${root}/etc/resolv.conf"
cp /etc/resolv.conf "${root}/etc/resolv.conf"

# What libcamera needs to build with the options build.sh uses (the same set
# Ubuntu's own packaging uses, less the tests and documentation).
build_deps=(
    build-essential ca-certificates git meson ninja-build pkgconf dpkg-dev openssl
    python3 libpython3-dev python3-jinja2 python3-ply python3-yaml python3-pybind11
    libdrm-dev libdw-dev libevent-dev libgnutls28-dev libjpeg-dev liblttng-ust-dev
    libpisp-dev libsdl2-dev libtiff-dev libudev-dev libyaml-dev libyuv-dev
    libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev qt6-base-dev
)

echo "[+] Building in the ${release} chroot"
chroot "${root}" /bin/bash -euo pipefail -c '
export DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8
apt-get update -qq
apt-get install -y -qq --no-install-recommends '"${build_deps[*]}"' >/dev/null
/cameras/build.sh /out
echo "[+] Installing the packages in the chroot to check them"
apt-get install -y -qq --no-install-recommends /out/*.deb >/dev/null
echo "--- libcamera $(dpkg -l | awk "/^ii +libcamera[0-9.]+ /{print \$3}")"
ldd /usr/bin/cam | grep "not found" && exit 1
LIBCAMERA_LOG_LEVELS="*:DEBUG" cam --list 2>&1 | grep -E "libcamera v|IPA module .* is signed|Found registered pipeline handler .rkisp2" | sed "s/^[^]]*\] \[[0-9]*\] *//"
python3 -c "import libcamera; print(\"python bindings import\")"
'
echo "[+] ${release} packages in ${OUT_DIR}:"
ls -l "${OUT_DIR}"/*.deb
