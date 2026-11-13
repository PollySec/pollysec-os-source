#!/bin/bash
#
# Runs INSIDE Flatcar's SDK container (collect-source.sh starts it): fetches
# the source archives of the listed packages for the amd64-usr board, with
# the board's USE flags, into the directory given. Portage checks each
# download against the package's Manifest and refuses a mismatch.
#
#   fetch-in-sdk.sh <atoms-file> <distdir>
set -euo pipefail
atoms_file="$1" distdir="$2"
if ! command -v emerge-amd64-usr >/dev/null; then
  /home/sdk/trunk/src/scripts/setup_board --board=amd64-usr --regen_configs_only
fi
mapfile -t atoms < "$atoms_file"
echo "fetching ${#atoms[@]} packages into $distdir"
# --keep-going: one dead upstream reports every failure in one run; the
# exit is still non-zero.
sudo DISTDIR="$distdir" emerge-amd64-usr --fetchonly --nodeps --keep-going --color=n "${atoms[@]}"
