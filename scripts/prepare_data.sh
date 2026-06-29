#!/usr/bin/env bash
# Extract the first N Gaia .csv.gz files into Data/csv/ as flat .csv files
# for the IRIS container mount. Idempotent: skips files already extracted.
# N defaults to 20 (the challenge scope) and is overridable via GAIA_NFILES
# (CI uses a smaller fixture set).
set -euo pipefail
SRC="${1:-Data}"
DST="${2:-Data/csv}"
N="${GAIA_NFILES:-20}"
mkdir -p "$DST"
for i in $(seq 0 $((N - 1))); do
  idx=$(printf '%03d' "$i")           # 0 -> 000, 19 -> 019
  f="$SRC/GaiaSource_000-000-${idx}.csv.gz"
  out="$DST/GaiaSource_000-000-${idx}.csv"
  [ -f "$f" ] || { echo "MISSING: $f" >&2; exit 1; }
  if [ ! -f "$out" ]; then
    echo "extracting $f" >&2
    gunzip -c "$f" > "$out"
  fi
done
echo "prepared $N files in $DST" >&2
