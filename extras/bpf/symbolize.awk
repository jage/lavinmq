# symbolize.awk: names the frames record.bt prints as addresses in the
# binary ("\t@<hex>", from its own unwinding of allocation stacks) as
# ustack does ("\tsymbol+offset"). Usage:
#   nm -n --defined-only BINARY | awk -v hi=<end of .text> -f symbolize.awk - a.trace
# The first input is nm's listing, sorted by address: its functions name
# addresses up to hi; an address outside them is [unknown], and @0 (no
# frame) is left out. Every other line passes through.

function hex(s,    v, i) {
  sub(/^0x/, "", s); s = tolower(s); v = 0
  for (i = 1; i <= length(s); i++) v = v * 16 + index("0123456789abcdef", substr(s, i, 1)) - 1
  return v
}

BEGIN { HI = hex(hi); N = 0 }

NR == FNR {
  if ($2 ~ /^[Tt]$/) {
    name = $0; sub(/^[0-9a-fA-F]+ [A-Za-z] /, "", name)
    A[N] = hex($1); S[N] = name; N++
  }
  next
}

/^\t@[0-9a-f]+$/ {
  a = hex(substr($0, 3))
  if (a == 0) next
  lo = 0; hi_ = N - 1; i = -1
  while (lo <= hi_) { m = int((lo + hi_) / 2); if (A[m] <= a) { i = m; lo = m + 1 } else hi_ = m - 1 }
  print ((i < 0 || a >= HI) ? "\t[unknown]" : "\t" S[i] "+" (a - A[i]))
  next
}

{ print }
