#!/usr/bin/env bash
# Build the RK3588 libcamera .debs from the fork pinned in source.conf.
#
# Builds libcamera with meson and packages it as:
#   libcamera0.8         the library, the IPA modules and tuning files, cam,
#                        libcamerify, the GStreamer plugin and Python bindings
#   libcamera0.8-qcam    qcam, the Qt viewer (desktop images only)
# The package name follows the soname, which follows libcamera's major.minor.
# The packages link against this release's libraries, so build on the Ubuntu
# release the image is for.
#
# Needs git, meson, ninja, dpkg-dev and libcamera's build dependencies (the
# same ones a plain meson build of the tree needs).
#
# Usage: build.sh [output dir]    (default: build/libcamera/<release>)
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=source.conf
source "${HERE}/source.conf"

die() { echo "Error: $*" >&2; exit 1; }

for tool in git meson ninja dpkg-deb dpkg-shlibdeps dpkg-architecture; do
    command -v "${tool}" >/dev/null || die "missing ${tool}"
done

codename="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
multiarch="$(dpkg-architecture -qDEB_HOST_MULTIARCH)"
arch="$(dpkg-architecture -qDEB_HOST_ARCH)"
OUT_DIR="${1:-${HERE}/../build/libcamera/${codename}}"
mkdir -p "${OUT_DIR}"
OUT_DIR="$(cd -- "${OUT_DIR}" && pwd)"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
src="${work}/src"
stage="${work}/stage"

echo "[+] Cloning ${FORK_URL} at ${FORK_SHA}"
git clone -q --filter=blob:none --no-checkout "${FORK_URL}" "${src}"
git -C "${src}" checkout -q "${FORK_SHA}"

# The fork has no upstream tags, so take the version from meson.build and use
# the commit count to keep builds ordered, and add the release so the packages
# built on different releases have different file names:
# 0.8.0+rk3588.6588.g86dfc5f5-1~resolute
upstream="$(sed -n "s/^ *version *: *'\\([0-9.]*\\)',\\?$/\\1/p" "${src}/meson.build" | head -1)"
[[ -n ${upstream} ]] || die "could not read the libcamera version from meson.build"
# libcamera builds the version it prints (cam, qcam, logs) with `git describe`.
# The fork has no upstream tags, so without one it reads v0.0.0+<commits>. Tag
# the commit that released this version, found by its subject. `git describe`
# only counts annotated tags.
if ! git -C "${src}" rev-parse -q --verify "refs/tags/v${upstream}" >/dev/null; then
    released="$(git -C "${src}" log -1 --format=%H --grep="^libcamera v${upstream}\$")"
    [[ -z ${released} ]] || git -C "${src}" -c user.name=build -c user.email=build@localhost \
        tag -a -m "libcamera v${upstream}" "v${upstream}" "${released}"
fi
commits="$(git -C "${src}" rev-list --count HEAD)"
short="$(git -C "${src}" rev-parse --short=8 HEAD)"
version="${upstream}+rk3588.${commits}.g${short}-1~${codename}"
lib_pkg="libcamera${upstream%.*}"
echo "[+] Building ${lib_pkg} ${version} on ${codename}"

meson setup "${work}/build" "${src}" \
    --prefix=/usr --libdir="lib/${multiarch}" --buildtype=release \
    -Dwerror=false -Dtest=false -Ddocumentation=disabled \
    -Dpipelines=rkisp2,simple,uvcvideo -Dipas=rkisp2,softisp \
    -Dcam=enabled -Dqcam=enabled -Dlc-compliance=enabled \
    -Dgstreamer=enabled -Dpycamera=enabled -Dv4l2=enabled \
    -Dpython.platlibdir=lib/python3/dist-packages \
    -Dpython.purelibdir=lib/python3/dist-packages
ninja -C "${work}/build"
# --strip happens before meson's install script signs the IPA modules, so the
# signatures stay valid.
meson install -C "${work}/build" --destdir "${stage}" --strip >/dev/null

# Development files are not needed in an image.
rm -rf "${stage}/usr/include" "${stage}/usr/lib/${multiarch}/pkgconfig"
find "${stage}/usr/lib/${multiarch}" -maxdepth 1 -name '*.so' -type l -delete
find "${stage}/usr/lib/python3" -name __pycache__ -type d -prune -exec rm -rf {} +

# Split qcam out.
qcam_stage="${work}/qcam"
mkdir -p "${qcam_stage}/usr/bin"
mv "${stage}/usr/bin/qcam" "${qcam_stage}/usr/bin/"
for f in "${stage}"/usr/share/applications/*qcam* "${stage}"/usr/share/icons/hicolor/*/apps/*qcam*; do
    [[ -e ${f} ]] || continue
    rel="${f#"${stage}"/}"
    mkdir -p "${qcam_stage}/$(dirname "${rel}")"
    mv "${f}" "${qcam_stage}/${rel}"
done

# Dependencies from the shared libraries each package links. libcamera's own
# libraries come from the same package, so tell dpkg-shlibdeps about them.
deps_for() {
    local root="$1" tmp
    tmp="$(mktemp -d -p "${work}")"
    mkdir -p "${tmp}/debian"
    printf 'Source: libcamera\n\nPackage: %s\nArchitecture: %s\n' "${lib_pkg}" "${arch}" > "${tmp}/debian/control"
    printf 'libcamera %s %s (= %s)\nlibcamera-base %s %s (= %s)\n' \
        "${upstream%.*}" "${lib_pkg}" "${version}" "${upstream%.*}" "${lib_pkg}" "${version}" \
        > "${tmp}/debian/shlibs.local"
    local -a elfs=()
    while IFS= read -r f; do
        if [[ $(head -c4 "${f}" | od -An -c | tr -d ' ') == '177ELF' ]]; then elfs+=("-e${f}"); fi
    done < <(find "${root}" -type f \( -perm -u+x -o -name '*.so*' \) ! -type l)
    # Drop dependencies on libcamera's own package (a package cannot depend on
    # itself, and the qcam package adds its own exact one).
    (cd "${tmp}" && dpkg-shlibdeps -O "-l${stage}/usr/lib/${multiarch}" "${elfs[@]}" 2>/dev/null) \
        | sed -n 's/^shlibs:Depends=//p' | tr ',' '\n' | sed 's/^ *//' \
        | grep -v "^${lib_pkg} " | paste -sd, | sed 's/,/, /g'
}

python_ver="$(find "${stage}/usr/lib/python3" -name '_libcamera*.so' | sed -n 's/.*cpython-\([0-9]\)\([0-9]*\)-.*/\1.\2/p' | head -1)"
runtime_deps="$(deps_for "${stage}")"
qcam_deps="$(deps_for "${qcam_stage}")"
if [[ -n ${python_ver} ]]; then
    runtime_deps+="${runtime_deps:+, }python3 (>= ${python_ver}), python3 (<< ${python_ver%.*}.$((${python_ver#*.} + 1)))"
fi

# Ubuntu's own libcamera packages own the same files and the IPA modules are
# signed per build, so the two sets must not be mixed.
ubuntu_set="libcamera0.7, libcamera-ipa, libcamera-tools, libcamera-v4l2, gstreamer1.0-libcamera, python3-libcamera"

write_deb() { # name, root, depends, description, conflicts
    local name="$1" root="$2" depends="$3" desc="$4" conflicts="$5"
    mkdir -p "${root}/DEBIAN"
    {
        echo "Package: ${name}"
        echo "Version: ${version}"
        echo "Architecture: ${arch}"
        echo "Section: libs"
        echo "Priority: optional"
        echo "Maintainer: Peyton Howe <peyton@localhost>"
        echo "Installed-Size: $(du -sk --exclude=DEBIAN "${root}" | cut -f1)"
        [[ -n ${depends} ]] && echo "Depends: ${depends}"
        echo "Conflicts: ${conflicts}"
        echo "Replaces: ${conflicts}"
        echo "Description: ${desc}"
        echo " libcamera from ${FORK_URL},"
        echo " branch rkisp2-upstream at ${FORK_SHA}, with the RK3588 rkisp2"
        echo " pipeline handler and IPA."
    } > "${root}/DEBIAN/control"
    echo "activate-noawait ldconfig" > "${root}/DEBIAN/triggers"
    dpkg-deb --root-owner-group -Zxz -b "${root}" "${OUT_DIR}/${name}_${version}_${arch}.deb" >/dev/null
}

# A rebuild of the same version replaces the old files.
rm -f "${OUT_DIR}/${lib_pkg}_"*.deb "${OUT_DIR}/${lib_pkg}-qcam_"*.deb
write_deb "${lib_pkg}" "${stage}" "${runtime_deps}" \
    "libcamera with the RK3588 rkisp2 pipeline handler" "${ubuntu_set}"
write_deb "${lib_pkg}-qcam" "${qcam_stage}" "${lib_pkg} (= ${version})${qcam_deps:+, ${qcam_deps}}" \
    "qcam, the libcamera Qt viewer" "qcam, libcamera-tools"

echo "[+] Built:"
ls -l "${OUT_DIR}"/*.deb
