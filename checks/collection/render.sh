#!/bin/zsh
# Run from the repo root. The optional arguments are licensed external RAWs.
set -eu
out=research/filter-collection-rebuild
repo=(research/proRAWs/IMG_{6929,6930,6931,6933,6934}.DNG
      research/dngs/{steve,clouds,street2,sidewalk,"back windows","home hallway","yellow garage"}.dng
      research/phase22-leica/inputs/Apple-iPhone-12-Pro.DNG)
rtk proxy /usr/bin/time -l /tmp/bettercam-collection "$out/renders" small "${repo[@]}" "$@" > "$out/renders.log" 2>&1
rtk proxy /tmp/bettercam-collection-old "$out/renders" small "${repo[@]}" "$@" > "$out/before.log" 2>&1
rtk proxy /usr/bin/time -l /tmp/bettercam-collection-parity --full48 > "$out/parity.log" 2>&1
rtk proxy /usr/bin/time -l /tmp/bettercam-collection "$out/native" monochrome research/proRAWs/IMG_6931.DNG > "$out/native-12.log" 2>&1
rtk proxy /usr/bin/time -l /tmp/bettercam-collection "$out/native" chroma research/proRAWs/IMG_6932.DNG > "$out/native-48.log" 2>&1
