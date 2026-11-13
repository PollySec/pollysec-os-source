# PollySec OS source

The complete corresponding source code of **PollySec OS**, the operating
system of the PollySec sensor appliance. PollySec OS is based on Flatcar
Container Linux: each appliance version holds the programs of one Flatcar
Container Linux release, unmodified, with the PollySec sensor and its
configuration added beside them. In the boot configuration Flatcar keeps in
the OEM partition, PollySec adds the appliance's boot settings and removes
the console's automatic login.

Flatcar is a trademark of LF Projects, LLC. PollySec OS is produced by
PollySec AB. Neither the Flatcar project nor LF Projects, LLC produces,
endorses or supports it.

## Where the source is

One [release](../../releases) per Flatcar Container Linux release, named
after its version (for example `4081.3.12`). The `NOTICE.txt` in every
appliance image names the release that holds its source, and so does the
PollySec Console where it offers the image for download. Each release
holds:

| File | What it is |
|---|---|
| `flatcar-scripts-<channel>-<version>.tar.gz` | Flatcar's build scripts, package definitions (ebuilds), patches and kernel configuration: the [flatcar/scripts](https://github.com/flatcar/scripts) repository at the release tag |
| `pollysec-os-source-<version>.tar.part-NN` | the source of every package on the appliance's disks, in one tar split into parts under 2 GiB: each source archive a package definition names, and, for a package built from a git commit, that repository at that commit with its submodules |
| `SOURCES.SHA256SUMS` | the SHA-256 of each archive in that tar |
| `PACKAGES.txt` | every package on the disks, with its version |
| `*_packages.txt` | the package lists Flatcar published for the release, which `PACKAGES.txt` is made from |
| `SOURCE-INFO.txt` | the tag and its commit, the SDK, when the source was collected, and the repository and commit of each package built from git |
| `SHA256SUMS` | every file of the release |

To unpack and check the source:

```
sha256sum -c SHA256SUMS
cat pollysec-os-source-<version>.tar.part-* > sources.tar
mkdir sources && tar -xf sources.tar -C sources
(cd sources && sha256sum -c ../SOURCES.SHA256SUMS)
```

What is on the appliance's disks, and so in the source: the Flatcar
production image with the system extensions built into it (containerd and
docker), the OEM extensions of the VMware and QEMU images, the boot loaders
on the EFI system partition (GRUB and shim), the Linux kernel, and the
Hyper-V OEM package.

## How it is collected

[`collect-source.sh`](collect-source.sh), run by the workflow in
[`.github/workflows/source.yml`](.github/workflows/source.yml) with no
credentials (a second job, which runs nothing else, publishes the result):

1. Flatcar's package lists for the release are downloaded from Flatcar's
   release server and accepted only with the SHA-512 that Flatcar's signed
   `DIGESTS` gives for them (key `F88CFEDEFF29A5B4D9523864E25D9AED0593B34A`,
   [`flatcar-image-signing-key.asc`](flatcar-image-signing-key.asc)).
2. flatcar/scripts is cloned at the release tag, which must be the commit
   pinned in [`pins/<version>.env`](pins), and archived.
3. Each package built from a git commit is cloned from the repository its
   package definition names, at that commit, with its submodules.
4. Flatcar's SDK, the image the tag pins, by the digest in `pins/`, fetches
   the source archives of every package with the board's settings
   ([`fetch-in-sdk.sh`](fetch-in-sdk.sh)). Portage checks every download
   against the package's Manifest.

### Adding a release

Before an appliance version based on a new Flatcar release is offered:
review the release and add `pins/<version>.env` (the tag's commit, the SDK
image's digest, and the packages on the disks that no list names), then run
the workflow with that version. A published release is never replaced.

## Asking for a copy

For at least three years after PollySec AB last distributes an appliance
version, PollySec AB will give anyone who asks, free of charge, a complete
machine-readable copy of the corresponding source code of the software in
it that is licensed under the GNU GPL, the GNU LGPL, the Mozilla Public
License or any other licence that asks for it, on a medium customarily used
for software interchange or by download. Write to **hello@pollysec.com** and
name the appliance version or the Flatcar release.

## Licences

Each package carries its own licence: the GNU GPL (versions 2 and 3), the
LGPL, the MPL and permissive licences among them. The licence of each
package is in its package definition in `flatcar-scripts-*.tar.gz` and in
Flatcar's licence manifest for the release
(`flatcar_production_image_licenses.json` on Flatcar's release server, and
in every image under `/usr/share/licenses/`). The scripts in this repository
are PollySec's own and are provided as they are.
