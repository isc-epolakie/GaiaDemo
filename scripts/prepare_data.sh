#!/usr/bin/env bash
# Extract the first N Gaia .csv.gz files into Data/csv/ as flat .csv files
# for the IRIS container mount. Idempotent: re-extracts only when the source
# .gz is missing-from / newer-than the extracted .csv — so it stays fast on
# repeat runs, yet never serves STALE data when the source changes (e.g.
# switching DATA=tests/fixtures and DATA=Data in the same checkout).
# N defaults to 20 (the challenge scope) and is overridable via GAIA_NFILES
# (CI uses a smaller fixture set).
set -euo pipefail
SRC="${1:-Data}"
DST="${2:-Data/csv}"
N="${GAIA_NFILES:-20}"
mkdir -p "$DST"

# If the destination was last populated from a DIFFERENT source dir, clear it so
# we never serve stale data when switching sources (e.g. tests/fixtures <-> Data)
# in the same checkout. The marker keeps same-source repeat runs fast (no
# needless re-extraction — important for the benchmark).
marker="$DST/.source"
src_abs="$(cd "$SRC" 2>/dev/null && pwd || echo "$SRC")"
if [ -f "$marker" ] && [ "$(cat "$marker")" != "$src_abs" ]; then
  echo "source changed -> clearing $DST" >&2
  rm -f "$DST"/GaiaSource_*.csv
fi
printf '%s' "$src_abs" > "$marker"

for i in $(seq 0 $((N - 1))); do
  idx=$(printf '%03d' "$i")           # 0 -> 000, 19 -> 019
  f="$SRC/GaiaSource_000-000-${idx}.csv.gz"
  out="$DST/GaiaSource_000-000-${idx}.csv"
  [ -f "$f" ] || { echo "MISSING: $f" >&2; exit 1; }
  # (re)extract if absent or the source .gz is newer than the extracted .csv
  if [ ! -f "$out" ] || [ "$f" -nt "$out" ]; then
    echo "extracting $f" >&2
    gunzip -c "$f" > "$out"
  fi
done
echo "prepared $N files in $DST" >&2
