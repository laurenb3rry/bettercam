#!/bin/zsh
# Run from the repo root. The optional FULL=1 runs native exports serially.
set -eu
work=$(rtk proxy mktemp -d "${TMPDIR:-/tmp}/bettercam-leica.XXXXXX")
trap 'rtk proxy rm -rf -- "$work"' EXIT
out=research/phase22-leica
rtk proxy mkdir -p "$out" "$work/modules"
rtk proxy python3 - "$work/Filters.swift" <<'PY'
from pathlib import Path
import sys

source = Path("BetterCam/Filters.swift").read_text()
start = source.index("    static let leicaM6 =")
end = source.index("\n\n", start)
archived = Path("checks/leica/revision26.txt").read_text().rstrip()
Path(sys.argv[1]).write_text(source[:start] + archived + source[end:])
PY
rtk proxy swiftc -O -suppress-warnings -module-cache-path "$work/modules" -o "$work/m6" \
  BetterCam/Look.swift BetterCam/Filters.swift checks/leica/main.swift
rtk proxy swiftc -O -suppress-warnings -module-cache-path "$work/modules" -o "$work/r26" \
  BetterCam/Look.swift "$work/Filters.swift" checks/leica/main.swift
if (( $# == 0 )); then
  set -- research/dngs/{street2,clouds,steve}.dng research/proRAWs/IMG_{6931,6932,6934}.DNG
fi
for source in "$@"; do
  name=${source:t:r}
  for mode in input r26 m6; do
    runner=m6
    if [[ $mode == r26 ]]; then runner=r26; fi
    rtk proxy "$work/$runner" "$mode" small "$source" "$out/$name-$mode.jpg"
    if [[ ${FULL:-0} == 1 ]]; then
      rtk proxy /usr/bin/time -l "$work/$runner" "$mode" full "$source" "$out/$name-$mode-full.jpg"
    fi
  done
done
rtk proxy python3 checks/leica/sheets.py
