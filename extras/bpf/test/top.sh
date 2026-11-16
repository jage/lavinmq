#!/bin/sh
# top.sh: top.awk draws the reports of a canned bpftrace run (test/top.in,
# with the map formats of bpftrace 0.20 and 0.25) as test/top.expected.
# takes keys (test/top.keys.expected), shows one fiber
# (test/top.fiber.expected), sums reports (test/top.window.expected) and
# drops WAIT when told. AWK picks the awk (gawk, mawk, busybox awk).
set -eu
dir=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
${AWK:-awk} -v pid=123 -v exe=lavinmq -v interval=1 -v sort=busy -v top=15 -v io=1 -v wait=1 -v proc=/nonexistent \
  -f "$dir/top.awk" "$dir/test/top.in" 2> /dev/null | diff -u "$dir/test/top.expected" -
# keys: sort by the next column (block), and filter on "o" then "op"
{ printf 'K\t>\nK\t/\nK\tO\nK\tp\nK\tenter\n'; cat "$dir/test/top.in"; } |
  ${AWK:-awk} -v pid=123 -v exe=lavinmq -v interval=1 -v sort=busy -v top=15 -v io=1 -v wait=1 -v proc=/nonexistent \
    -f "$dir/top.awk" 2> /dev/null | diff -u "$dir/test/top.keys.expected" -
# one fiber: the third row, selected and opened
{ printf 'K\tdown\nK\tdown\nK\tdown\n'; sed -n '1,/^E$/p' "$dir/test/top.in"; printf 'K\tenter\n'; sed '1,/^E$/d' "$dir/test/top.in"; } |
  ${AWK:-awk} -v pid=123 -v exe=lavinmq -v interval=1 -v sort=busy -v top=15 -v io=1 -v wait=1 -v window=2 -v proc=/nonexistent \
    -f "$dir/top.awk" 2> /dev/null | diff -u "$dir/test/top.fiber.expected" -
# the last two reports summed
${AWK:-awk} -v pid=123 -v exe=lavinmq -v interval=1 -v sort=busy -v top=15 -v io=1 -v wait=1 -v window=2 -v proc=/nonexistent \
  -f "$dir/top.awk" "$dir/test/top.in" 2> /dev/null | diff -u "$dir/test/top.window.expected" -
# no WAIT after all, told once top.awk has started: as started without
{ printf 'W\t0\n'; cat "$dir/test/top.in"; } |
  ${AWK:-awk} -v pid=123 -v exe=lavinmq -v interval=1 -v sort=wait -v top=15 -v io=1 -v wait=1 -v proc=/nonexistent \
    -f "$dir/top.awk" 2> /dev/null > "$tmp"
${AWK:-awk} -v pid=123 -v exe=lavinmq -v interval=1 -v sort=busy -v top=15 -v io=1 -v wait=0 -v proc=/nonexistent \
  -f "$dir/top.awk" "$dir/test/top.in" 2> /dev/null | diff -u - "$tmp"
echo "top.awk: ok"
