#!/usr/bin/env bash
# Scaffold an ecc.toml design directory from Verilog sources.
#
#   new-design.sh <out-dir> <top> <clock-port> <freq-mhz> <rtl.v>...
#
# The RTL is copied into <out-dir>/src so the design directory is
# self-contained; the PDK is chosen at create time (--pdk-root/--pdk-id).
set -euo pipefail

if [ "$#" -lt 5 ]; then
  sed -n '2,7p' "$0" >&2
  exit 2
fi
out=$1 top=$2 clock=$3 freq=$4
case $freq in *.*) ;; *) freq="$freq.0" ;; esac
shift 4

if [ -e "$out/ecc.toml" ]; then
  echo "refusing to overwrite $out/ecc.toml" >&2
  exit 1
fi
mkdir -p "$out/src"
rtl=()
for file in "$@"; do
  cp "$file" "$out/src/"
  chmod u+w "$out/src/$(basename "$file")"
  rtl+=("\"src/$(basename "$file")\"")
done

cat >"$out/ecc.toml" <<EOF
[design]
name = "$top"
top = "$top"
rtl = [$(IFS=,; echo "${rtl[*]}" | sed 's/,/, /g')]
clock_port = "$clock"
frequency_mhz = $freq

[pdk]
name = "ics55"
root = ""

[flow]
preset = "rtl2gds"
EOF
echo "$out/ecc.toml"
