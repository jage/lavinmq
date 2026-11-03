# symbolize.awk: names the frames record.bt prints as addresses ("\t0x...",
# addresses in the binary) as ustack does ("\tsymbol+offset"). Usage:
#   nm -n --defined-only BINARY | awk -f symbolize.awk - a.trace
# The first input is nm's listing, sorted by address; the rest passes
# through with those lines replaced.

NR == FNR {
  if ($2 ~ /^[TtWw]$/) {
    name = $0; sub(/^[0-9a-fA-F]+ [A-Za-z] /, "", name)
    A[N] = hex($1); S[N++] = name
  }
  next
}

/^\t0x[0-9a-f]+$/ {
  a = hex(substr($0, 4))
  lo = 0; hi = N - 1; i = -1
  while (lo <= hi) { m = int((lo + hi) / 2); if (A[m] <= a) { i = m; lo = m + 1 } else hi = m - 1 }
  print i < 0 ? $0 : "\t" S[i] "+" (a - A[i])
  next
}

{ print }

function hex(s,    v, i, c) {
  v = 0; s = tolower(s)
  for (i = 1; i <= length(s); i++) { c = index("0123456789abcdef", substr(s, i, 1)); v = v * 16 + c - 1 }
  return v
}
