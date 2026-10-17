#!/usr/bin/env bash
# Summarize ECC workspaces of one project, one table row per workspace.
#
#   sweep-table.sh <project-dir> <workspace>...
#
# ECC is the ECC command line (default `ecc`), for example
#   ECC="$HOME/ECOS-Studio_0.1.0-alpha.9_x86_64.AppImage --cli ecc"
# Columns: flow status, signoff status (the real success criterion), first
# failed step, die area, core utilization, achieved Fmax.
set -euo pipefail

if [ "$#" -lt 2 ]; then
  sed -n '2,9p' "$0" >&2
  exit 2
fi
read -ra ecc <<<"${ECC:-ecc}"
project=$(cd "$1" && pwd)
shift

# Value of `key=` on the first `--plain` line that starts with <prefix>=.
# Launchers (AppImage, appimage-run) may print their own lines first.
field() { grep -m 1 "^$1=" | grep -oE "(^| )$2=[^ ]+" | head -n 1 | sed 's/^ //; s/^[^=]*=//'; }

# Value column of one row of the design summary report.
summary_value() { sed -n "s/^  $1  *\([^ ]*\( [^ ]*\)\{0,1\}\).*/\1/p" "$2" | head -n 1; }

printf '%-12s %-8s %-10s %-14s %-12s %-6s %s\n' \
  workspace flow signoff failed_step die_area util fmax
for ws in "$@"; do
  status_out=$("${ecc[@]}" status --project "$project" --workspace "$ws" --plain 2>/dev/null || true)
  flow=$(field workspace_id status <<<"$status_out" || true)
  failed=$(grep -E '^step=.* status=(failed|incomplete) ' <<<"$status_out" | field step step || true)

  signoff=-
  if [ "$flow" = success ]; then
    signoff=$("${ecc[@]}" signoff inspect --project "$project" --workspace "$ws" --plain 2>/dev/null |
      field signoff status || true)
  fi

  die=- util=- fmax=-
  "${ecc[@]}" report summary --project "$project" --workspace "$ws" >/dev/null 2>&1 || true
  report=$(ls "$project/$ws"/signoff/*_design_summary.txt 2>/dev/null | head -n 1 || true)
  if [ -n "$report" ]; then
    die=$(summary_value 'Die Area' "$report")
    util=$(summary_value 'Core Utilization' "$report")
    fmax=$(summary_value 'Achieved Fmax' "$report")
  fi

  printf '%-12s %-8s %-10s %-14s %-12s %-6s %s\n' \
    "$ws" "${flow:-?}" "${signoff:--}" "${failed:--}" "${die:--}" "${util:--}" "${fmax:--}"
done
