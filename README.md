# rk3588-cameras

Camera support for the Rockchip RK3588 on stock Ubuntu kernels: out-of-tree
kernel drivers, device-tree overlays, and libcamera with the rkisp2 pipeline
handler. It is built into prebuilt `.deb` packages that an image builder (see
[ubuntu-image-builder](https://github.com/peyton-howe/ubuntu-image-builder))
or a running system installs.

| Directory | Package | What it is |
|---|---|---|
| `dkms/` | `rk3588-camera-dkms` | DKMS drivers: the `rkisp2` ISP, the `rkcif` capture driver, the Samsung DCPHY CSI receiver, and sensor drivers (`imx708`, `imx415` with a 2376 Mbps lane rate, `imx477`, `imx519`). `arch: all`; the modules are built on the device against its kernel |
| `overlays/` | `rk3588-camera-overlays` | One `.dtbo` per sensor, the ISP overlays, and `apply-overlays.sh`, which writes the selected cameras into the boot configuration (Raspberry Pi `dtoverlay` style). `arch: all` |
| `libcamera/` | `libcamera0.8` | [libcamera](https://github.com/peyton-howe/libcamera) (branch `rkisp2-upstream`, pinned in `libcamera/source.conf`) with the RK3588 rkisp2 pipeline handler and IPA, and the tuning files for the supported sensors. Built per Ubuntu release |
| `docs/` | | Bring-up notes, and the findings behind the hangs and limits we have hit |

Supported cameras, boards and ports are listed in the image builder's README
and in `overlays/overlays.conf`.

## Building

The two `arch: all` packages:

```sh
sudo apt install debhelper dh-dkms device-tree-compiler dpkg-dev gcc python3
./scripts/build-debs.sh          # -> build/debs/
```

libcamera is built once per Ubuntu release, because the package links against
that release's libraries. `libcamera/build-in-chroot.sh` does it in a throwaway
chroot made from Ubuntu's own base image for the release (resolute or stonking),
so it works from any arm64 host, installs the result in the chroot and checks
that libcamera loads its signed `rkisp2` IPA module:

```sh
./libcamera/build-in-chroot.sh resolute   # -> build/libcamera/resolute/
./libcamera/build-in-chroot.sh stonking   # -> build/libcamera/stonking/
```

It needs root (it uses `sudo`), network access, and `curl`. To build on a machine
that already runs the target release and has libcamera's build dependencies, run
`./libcamera/build.sh` instead.

Overlay tests (need `gcc`, `dtc`, `fdtoverlay` and `python3`):

```sh
./overlays/tests/test-apply.sh
```

## Releasing

```sh
./scripts/make-release.sh release build/debs build/libcamera/resolute build/libcamera/stonking
```

collects the packages and a `SHA256SUMS` manifest. Publish them as the assets of
a release; consumers pin the release tag and the hash of `SHA256SUMS`, then
verify every package against it.

GitHub Actions does this ([build.yml](.github/workflows/build.yml)). Every push
and pull request runs the overlay tests and builds all the packages; the
libcamera packages are built for each Ubuntu release in a chroot on an arm64
runner. Pushing a tag `vMAJOR.MINOR.PATCH` also publishes the release, and the
job summary shows the `SHA256SUMS` hash to pin:

```sh
git tag v0.1.0 && git push origin v0.1.0
```

## apt repository

Every push to `main` also publishes the packages for Ubuntu 26.10 (`stonking`,
arm64) to a signed apt repository, `apt/conf/distributions`, kept in a
Cloudflare R2 bucket and served at `https://apt.tachynlabs.com`:

```sh
sudo curl -fsSL https://apt.tachynlabs.com/tachyn-archive-keyring.gpg -o /usr/share/keyrings/tachyn.gpg
echo "deb [signed-by=/usr/share/keyrings/tachyn.gpg] https://apt.tachynlabs.com stonking main" | \
    sudo tee /etc/apt/sources.list.d/tachyn.list
sudo apt update
```

A package version is published once and never replaced, so a change to
`rk3588-camera-dkms` or `rk3588-camera-overlays` needs a new `debian/changelog`
version to reach the repository (libcamera's version follows its commit count,
so a new pin publishes by itself). The publish job skips a version the suite
already has. `scripts/apt-add-debs.sh` does the adding and can be run on its
own against a local `reprepro` directory.

## Relationship to the image builder

- The image builder's board packages build the base DTB for each board (with
  `__symbols__`) and ship that board's CSI port overlays, built against the
  kernel's own `dt-bindings`, plus a marker
  `/usr/share/rk3588-camera/boards/<name>.conf` (`name`, `prefix`, `ports`).
  `apply-overlays.sh` reads the marker, so a new board only touches the image
  builder. `overlays/tests/ports/` keeps a few port overlays as test fixtures.
- The kernel patch series that the DKMS sources started from still lives in the
  image builder. The sources here are what is maintained now.
