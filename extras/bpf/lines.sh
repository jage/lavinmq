#!/usr/bin/env bash
# lines.sh <binary> <frames.tsv>: maps the "function<TAB>offset<TAB>leaf<TAB>
# count" rows fold.awk writes to source lines, using the binary's line tables
# (release builds have them). Prints "function<TAB>file:line<TAB>inlined
# function<TAB>samples", most samples first. Needs nm plus llvm-symbolizer or
# addr2line; prints nothing without them.
set -euo pipefail
bin=$1 frames=$2
command -v nm > /dev/null || exit 0
if command -v llvm-symbolizer > /dev/null; then
  symbolize() { llvm-symbolizer --obj="$bin" --inlining --addresses --output-style=GNU; }
elif command -v addr2line > /dev/null; then
  symbolize() { addr2line -e "$bin" -a -i -f; }
else
  exit 0
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# unique (function, offset, leaf) with sample counts
awk -F'\t' '{ c[$1 FS $2 FS $3] += $4 } END { for (k in c) print k FS c[k] }' "$frames" > "$tmp/agg"
# symbol addresses; names can contain spaces
nm --defined-only "$bin" | awk '{ print $1 "\t" substr($0, length($1) + length($2) + 3) }' > "$tmp/syms"

# address of each sample: symbol + offset, minus 1 for return addresses (the
# call instruction is the line that matters)
awk -F'\t' '
  function hex2dec(h,    i, d) { d = 0; for (i = 1; i <= length(h); i++) d = d * 16 + index("0123456789abcdef", substr(h, i, 1)) - 1; return d }
  function dec2hex(d,    h) { h = ""; while (d > 0) { h = substr("0123456789abcdef", d % 16 + 1, 1) h; d = int(d / 16) }; return h == "" ? "0" : h }
  NR == FNR { addr[$2] = $1; next }
  # a leaf at +n and a caller at +n+1 are the same address: add them up
  ($1 in addr) { a = "0x" dec2hex(hex2dec(addr[$1]) + $2 - ($3 ? 0 : 1)); fn[a] = $1; c[a] += $4 }
  END { for (a in c) print a "\t" fn[a] "\t" c[a] }
' "$tmp/syms" "$tmp/agg" > "$tmp/addrs"
[ -s "$tmp/addrs" ] || exit 0

cut -f1 "$tmp/addrs" | symbolize > "$tmp/sym" 2> /dev/null || true

# GNU style: "0xaddr", then function/file:line pairs, innermost inline first
awk -F'\t' '
  function short(p) {
    sub(/ \(discriminator [0-9]+\)$/, "", p)
    if (match(p, /\/share\/crystal\/src\//)) return "crystal/" substr(p, RSTART + RLENGTH)
    if (match(p, /\/lib\/[^\/]+\/src\//)) return substr(p, RSTART + 1)
    # the last /src/: a checkout under ~/src/lavinmq has two
    n = split(p, parts, "/src/")
    if (n > 1) return "src/" parts[n]
    return p
  }
  function flush() {
    if (cur != "" && loc != "" && loc !~ /\?\?/ && loc !~ /:0$/) print cur "\t" loc "\t" (depth > 2 ? fn1 : "")
    cur = ""; loc = ""; depth = 0
  }
  NR == FNR { s = $1; sub(/^0x0*/, "", s); key[s] = $2; cnt[s] = $3; next }
  /^0x[0-9a-f]+$/ { flush(); s = $0; sub(/^0x0*/, "", s); cur = s; next }
  cur != "" && depth % 2 == 0 { depth++; if (depth == 1) fn1 = $0; next }
  cur != "" { depth++; if (depth == 2) loc = short($0); next }
  END { flush() }
' "$tmp/addrs" "$tmp/sym" > "$tmp/resolved"

# per function and line: samples
awk -F'\t' '
  NR == FNR { s = $1; sub(/^0x0*/, "", s); key[s] = $2; cnt[s] = $3; next }
  ($1 in key) { k = key[$1] "\t" $2 "\t" $3; c[k] += cnt[$1] }
  END { for (k in c) print k "\t" c[k] }
' "$tmp/addrs" "$tmp/resolved" | sort -t$'\t' -k4,4nr
