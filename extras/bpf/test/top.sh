#!/bin/sh
# top.sh: top.awk draws the reports of a canned bpftrace run (test/top.in,
# with the map formats of bpftrace 0.20 and 0.25) as test/top.expected.
# takes keys (test/top.keys.expected) and sums reports
# (test/top.window.expected). AWK picks the awk (gawk, mawk, busybox awk).
set -eu
dir=$(cd "$(dirname "$0")/.." && pwd)
${AWK:-awk} -v pid=123 -v exe=lavinmq -v interval=1 -v sort=busy -v top=15 -v io=1 -v wait=1 -v proc=/nonexistent \
  -f "$dir/top.awk" "$dir/test/top.in" 2> /dev/null | diff -u "$dir/test/top.expected" -
# keys: sort by the next column (block), and filter on "o" then "op"
{ printf 'K\t>\nK\t/\nK\tO\nK\tp\nK\tenter\n'; cat "$dir/test/top.in"; } |
  ${AWK:-awk} -v pid=123 -v exe=lavinmq -v interval=1 -v sort=busy -v top=15 -v io=1 -v wait=1 -v proc=/nonexistent \
    -f "$dir/top.awk" 2> /dev/null | diff -u "$dir/test/top.keys.expected" -
# the last two reports summed
${AWK:-awk} -v pid=123 -v exe=lavinmq -v interval=1 -v sort=busy -v top=15 -v io=1 -v wait=1 -v window=2 -v proc=/nonexistent \
  -f "$dir/top.awk" "$dir/test/top.in" 2> /dev/null | diff -u "$dir/test/top.window.expected" -
echo "top.awk: ok"
