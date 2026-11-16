#!/usr/bin/env bash
# Add .debs to a reprepro repository and export its indexes. A package version
# the suite already has is skipped, not replaced: apt clients and reprepro both
# treat a version as immutable, so a change needs a new version.
#
# Usage: apt-add-debs.sh <repo dir> <suite> <deb>...
# The repo dir needs conf/distributions. Prints added=<n> (and writes it to
# $GITHUB_OUTPUT when that is set).
set -euo pipefail

repo="${1:?repository directory}"
suite="${2:?suite}"
shift 2
[[ $# -gt 0 ]] || { echo "Error: no .debs given" >&2; exit 1; }

added=0
for deb in "$@"; do
    name="$(dpkg-deb -f "${deb}" Package)"
    version="$(dpkg-deb -f "${deb}" Version)"
    have="$(reprepro -b "${repo}" listfilter "${suite}" "Package (== ${name}), Version (== ${version})")"
    if [[ -n ${have} ]]; then
        echo "skip ${name} ${version}: ${suite} already has it (bump the version to publish a change)"
        continue
    fi
    reprepro -b "${repo}" includedeb "${suite}" "${deb}"
    added=$((added + 1))
done
reprepro -b "${repo}" export "${suite}"

echo "added=${added}"
[[ -z ${GITHUB_OUTPUT:-} ]] || echo "added=${added}" >> "${GITHUB_OUTPUT}"
