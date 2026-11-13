#!/usr/bin/env bash
#
# Collects the complete corresponding source of PollySec OS for one Flatcar
# Container Linux release, the release the PollySec sensor appliance is
# built from:
#
#   - Flatcar's build scripts, package definitions (ebuilds), patches and
#     kernel configuration: the flatcar/scripts repository at the release
#     tag, as `git archive` gives it;
#   - the source of every package on the appliance's disks: each source
#     archive ("distfile") its ebuild names, fetched by Flatcar's own SDK,
#     which checks every download against the package's Manifest; and, for
#     the packages built from a git commit instead, that repository at that
#     commit (with its submodules);
#   - Flatcar's package lists for the release, verified against Flatcar's
#     signed DIGESTS, the resolved package list, and a SHA256SUMS.
#
# Only a release with a reviewed pins/<version>.env is collected: it pins
# the tag's commit, the SDK image by digest and the packages on the disks
# that no list names.
#
#   ./collect-source.sh <channel> <version> <out-dir>
#
# On a Linux x86-64 host with Docker. Needs no credentials: it only reads.
set -euo pipefail

CHANNEL="${1:-}" VERSION="${2:-}" OUT="${3:-}"
[[ "$CHANNEL" =~ ^(lts|stable)$ && -n "$OUT" ]] || { echo "usage: $0 <lts|stable> <version> <out-dir>" >&2; exit 2; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "STOPPED: '$VERSION' is not a Flatcar version like 4081.3.12" >&2; exit 2; }

fail() { echo "STOPPED: $*" >&2; exit 1; }
say() { echo "==> $*"; }

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PINS="$HERE/pins/$VERSION.env"
[[ -f "$PINS" ]] || fail "no pins/$VERSION.env: review the release and pin it first (README, Adding a release)"
TAG_COMMIT="" SDK_IMAGE="" EXTRA_ATOMS=""
# shellcheck source=/dev/null
source "$PINS"
[[ "$TAG_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "pins/$VERSION.env: TAG_COMMIT is not a commit"
[[ "$SDK_IMAGE" =~ ^ghcr\.io/flatcar/flatcar-sdk-amd64@sha256:[0-9a-f]{64}$ ]] || fail "pins/$VERSION.env: SDK_IMAGE is not the SDK by digest"
[[ -n "$EXTRA_ATOMS" ]] || fail "pins/$VERSION.env: EXTRA_ATOMS is empty"

# The primary key of Flatcar's image signing key ("Flatcar Buildbot
# (Official Builds) <buildbot@flatcar-linux.org>"), as published at
# https://www.flatcar.org/security/image-signing-key/.
KEY_FINGERPRINT=F88CFEDEFF29A5B4D9523864E25D9AED0593B34A
BASE="https://${CHANNEL}.release.flatcar-linux.net/amd64-usr/${VERSION}"
TAG="${CHANNEL}-${VERSION}"
PREFIX="pollysec-os-source-${VERSION}"

mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
[[ -z "$(ls -A "$OUT")" ]] || fail "$OUT is not empty"
WORK=$(mktemp -d)
# The SDK container leaves root-owned files behind.
trap 'rm -rf "$WORK" 2>/dev/null || sudo rm -rf "$WORK" || true' EXIT

# What is on the appliance's disks: the base image, every system extension
# built into it, and the OEM extensions of the VMware and QEMU (Proxmox)
# images. A Hyper-V OEM package list would be new: stop, and review it.
sysexts=$(curl -fsSL --proto '=https' --retry 3 "$BASE/rootfs-included-sysexts/" \
  | grep -o 'href="\./[^"]*_packages\.txt"' | sed 's/^href="\.\///; s/"$//' | LC_ALL=C sort -u) \
  || fail "cannot read the release's rootfs-included-sysexts index"
[[ -n "$sysexts" ]] || fail "the release lists no rootfs-included system extension: review it"
LISTS=(flatcar_production_image_packages.txt)
while read -r s; do LISTS+=("rootfs-included-sysexts/$s"); done <<< "$sysexts"
LISTS+=(oem-vmware_packages.txt oem-qemu_packages.txt)
code=$(curl -s -o /dev/null -L --retry 3 -w '%{http_code}' "$BASE/oem-hyperv_packages.txt") || code="no answer"
[[ "$code" == "404" ]] || fail "the release's oem-hyperv package list answers '$code', not 404: review it and pins/$VERSION.env"

# 1. The package lists, each accepted only with the SHA-512 that Flatcar's
#    signed DIGESTS gives for it.
say "verifying ${#LISTS[@]} package lists of $TAG"
GNUPG="$WORK/gnupg"
mkdir -m 700 "$GNUPG"
gpg --homedir "$GNUPG" --batch --quiet --import "$HERE/flatcar-image-signing-key.asc"
for list in "${LISTS[@]}"; do
  name=$(basename "$list")
  curl -fsSL --proto '=https' --retry 3 -o "$WORK/$name" "$BASE/$list" || fail "$list: not on Flatcar's release server"
  curl -fsSL --proto '=https' --retry 3 -o "$WORK/$name.DIGESTS.asc" "$BASE/$list.DIGESTS.asc" || fail "$list: no signed DIGESTS"
  status=$(gpg --homedir "$GNUPG" --batch --status-fd 1 --output "$WORK/$name.DIGESTS" --yes \
             --decrypt "$WORK/$name.DIGESTS.asc" 2>/dev/null) \
    || fail "$list: the signature over its DIGESTS does not verify"
  signer=$(awk '$1 == "[GNUPG:]" && $2 == "VALIDSIG" { print $NF }' <<< "$status")
  [[ "$signer" == "$KEY_FINGERPRINT" ]] || fail "$list: DIGESTS signed by '$signer', not Flatcar's key $KEY_FINGERPRINT"
  expected=$(awk -v name="$name" '/^# SHA512 HASH/ { inside = 1; next } /^#/ { inside = 0 } inside && $2 == name { print $1 }' "$WORK/$name.DIGESTS")
  [[ "$expected" =~ ^[0-9a-f]{128}$ ]] || fail "$list: no SHA-512 in its signed DIGESTS"
  actual=$(sha512sum "$WORK/$name" | cut -d' ' -f1)
  [[ "$actual" == "$expected" ]] || fail "$list: SHA-512 $actual, its signed DIGESTS says $expected"
  cp "$WORK/$name" "$OUT/$name"
done

# Every package, exactly as built: "=category/name-version".
for list in "${LISTS[@]}"; do cat "$OUT/$(basename "$list")"; done \
  | sed -E 's/::.*$//; /^[[:space:]]*$/d; s/^/=/' > "$WORK/atoms"
tr ' ' '\n' <<< "$EXTRA_ATOMS" | sed '/^$/d' >> "$WORK/atoms"
LC_ALL=C sort -u -o "$WORK/atoms" "$WORK/atoms"
grep -qvE '^=[a-z0-9+_.-]+/[A-Za-z0-9+_.-]+$' "$WORK/atoms" && fail "a package name is not an exact atom"
say "$(wc -l < "$WORK/atoms") packages"

# 2. Flatcar's scripts at the release tag, at the pinned commit.
say "cloning flatcar/scripts at $TAG"
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$TAG" \
  https://github.com/flatcar/scripts.git "$WORK/scripts"
commit=$(git -C "$WORK/scripts" rev-parse HEAD)
[[ "$commit" == "$TAG_COMMIT" ]] || fail "tag $TAG is commit $commit, pins/$VERSION.env pins $TAG_COMMIT"
git -C "$WORK/scripts" archive --format=tar.gz --prefix="flatcar-scripts-$TAG/" \
  -o "$OUT/flatcar-scripts-$TAG.tar.gz" HEAD
OVERLAYS="$WORK/scripts/sdk_container/src/third_party"

ebuild_of() {
  local atom="${1#=}" cat pv e
  cat="${atom%%/*}" pv="${atom#*/}"
  for e in "$OVERLAYS"/coreos-overlay/"$cat"/*/"$pv".ebuild "$OVERLAYS"/portage-stable/"$cat"/*/"$pv".ebuild; do
    [[ -f "$e" ]] && { echo "$e"; return 0; }
  done
  return 1
}

# 3. The packages built from a git commit (git-r3 with EGIT_COMMIT): that
#    repository at that commit, with its submodules, as a tar.
SOURCES="$WORK/sources"
mkdir -p "$SOURCES"
: > "$WORK/git-sources"
shopt -s nullglob
while read -r atom; do
  e=$(ebuild_of "$atom") || fail "$atom: no ebuild at $TAG"
  grep -qE '^[[:space:]]*inherit .*\bgit-r3\b' "$e" || continue
  grep -qE '^[[:space:]]*EGIT_COMMIT=' "$e" || continue
  egit_commit=$(grep -oE '^[[:space:]]*EGIT_COMMIT="[0-9a-f]{40}"' "$e" | grep -oE '[0-9a-f]{40}' | head -1 || true)
  [[ -n "$egit_commit" ]] || fail "$atom: EGIT_COMMIT is not a commit id this script can archive"
  repo=$(grep -oE '^[[:space:]]*EGIT_REPO_URI="https://[^" $]+"' "$e" | head -1 | sed -E 's/.*="//; s/"$//' || true)
  [[ "$repo" =~ ^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || fail "$atom: git source '$repo' is not a GitHub repository this script knows how to archive"
  pn=$(basename "$(dirname "$e")")
  dir="$WORK/git/$pn-$egit_commit"
  say "$atom: $repo at $egit_commit"
  git -c advice.detachedHead=false clone --quiet --no-checkout "$repo" "$dir"
  git -C "$dir" -c advice.detachedHead=false checkout --quiet "$egit_commit"
  git -C "$dir" submodule update --quiet --init --recursive
  tar --exclude-vcs --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 \
    -czf "$SOURCES/$pn-$egit_commit.tar.gz" -C "$WORK/git" "$pn-$egit_commit"
  echo "${atom#=} $repo $egit_commit" >> "$WORK/git-sources"
done < "$WORK/atoms"
shopt -u nullglob
say "$(wc -l < "$WORK/git-sources") packages built from a git commit"

# 4. The distfiles, fetched inside the pinned SDK into a directory of their
#    own, so that nothing else lands among them.
say "fetching the source archives with Flatcar's SDK"
cp "$WORK/atoms" "$WORK/scripts/pollysec-atoms.txt"
cp "$HERE/fetch-in-sdk.sh" "$WORK/scripts/pollysec-fetch-in-sdk.sh"
mkdir -p "$WORK/scripts/__build__/images/distfiles"
chmod 0777 "$WORK/scripts/__build__/images/distfiles"
(cd "$WORK/scripts" && ./run_sdk_container -U -a amd64 -C "$SDK_IMAGE" -n pollysec-source --rm \
   /mnt/host/source/src/scripts/pollysec-fetch-in-sdk.sh \
   /mnt/host/source/src/scripts/pollysec-atoms.txt /mnt/host/source/src/build/distfiles)
distfiles="$WORK/scripts/__build__/images/distfiles"
find "$distfiles" -maxdepth 1 -name '*.__download__' -print -quit | grep -q . && fail "an interrupted download is among the distfiles"
count=$(find "$distfiles" -maxdepth 1 -type f | wc -l)
(( count > 0 )) || fail "no source archive was fetched"
say "$count source archives"
for f in "$distfiles"/*; do
  [[ -f "$f" ]] || continue
  [[ ! -e "$SOURCES/$(basename "$f")" ]] || fail "$(basename "$f") is both a distfile and a git archive"
  ln "$f" "$SOURCES/" 2>/dev/null || cp "$f" "$SOURCES/"
done

# 5. One tar of every source archive, the SHA-256 of each, and the tar split
#    into parts under GitHub's 2 GiB limit for a release asset.
(cd "$SOURCES" && find . -maxdepth 1 -type f -printf '%f\n' | LC_ALL=C sort > "$WORK/names" \
   && xargs -d '\n' -a "$WORK/names" sha256sum) > "$OUT/SOURCES.SHA256SUMS"
tar --sort=name --owner=0 --group=0 --numeric-owner -cf - -C "$SOURCES" -T "$WORK/names" \
  | split -b 1900M -d -a 2 - "$OUT/$PREFIX.tar.part-"

# 6. What was collected from what, and the sums.
cp "$WORK/atoms" "$OUT/PACKAGES.txt"
{
  echo "PollySec OS source for Flatcar Container Linux $VERSION ($CHANNEL, amd64)"
  echo "flatcar/scripts tag $TAG, commit $commit"
  echo "SDK $SDK_IMAGE"
  echo "collected $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "packages: $(wc -l < "$WORK/atoms"), source archives: $count, built from a git commit: $(wc -l < "$WORK/git-sources")"
  echo
  echo "Packages built from a git commit (package, repository, commit):"
  cat "$WORK/git-sources"
} > "$OUT/SOURCE-INFO.txt"
(cd "$OUT" && find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%f\n' | LC_ALL=C sort \
   | xargs -d '\n' sha256sum > SHA256SUMS)
say "DONE: $OUT"
