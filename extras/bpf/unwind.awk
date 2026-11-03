# unwind.awk: how to step out of libgc's frames, which have no frame
# pointers, for record.bt's allocation stacks. Reads `readelf -wF` (the
# .eh_frame unwind rows) and `objdump -d` of libgc's code, and prints one
# bpftrace statement per call site in libgc:
#   @unwind[return address] = rule;
# Only calls on the way to the functions in `targets` are kept (calls of
# them, or of functions that call them, directly or by a tail call): fewer
# statements for bpftrace to compile. The rule, at that call: bits 0-15 how far above the stack pointer (bit 32
# set: the frame pointer) the frame's CFA is; bits 16-31 how far below the
# CFA the caller's frame pointer is saved, or 0; bits 40-55 how far below
# the CFA the return address is. Usage:
#   awk -v lo=0x... -v hi=0x... -v targets="F G" -f unwind.awk <(readelf -wF BIN) <(objdump -d --no-show-raw-insn ... BIN)

function hex(s,    v, i) {
  sub(/^0x/, "", s); s = tolower(s); v = 0
  for (i = 1; i <= length(s); i++) v = v * 16 + index("0123456789abcdef", substr(s, i, 1)) - 1
  return v
}
# "c-16" -> 16, "u" -> 0
function slot(s) { return s ~ /^c-[0-9]+$/ ? substr(s, 3) + 0 : 0 }

BEGIN { LO = hex(lo); HI = hex(hi); NF_ = NROW = NC = 0 }

# --- readelf -wF ---
# a CIE's initial row is not a row of the FDE before it
FNR == NR && / CIE / { in_fde = 0; next }
FNR == NR && / FDE / {
  match($0, /pc=[0-9a-f]+\.\.[0-9a-f]+/)
  split(substr($0, RSTART + 3, RLENGTH - 3), r, /\.\./)
  in_fde = hex(r[1]) < HI && hex(r[2]) > LO
  if (in_fde) { FLO[NF_] = hex(r[1]); FHI[NF_] = hex(r[2]); FROW[NF_++] = NROW }
  next
}
FNR == NR && in_fde && $1 == "LOC" {
  cfa_col = fp_col = ra_col = 0
  for (i = 2; i <= NF; i++) {
    if ($i == "CFA") cfa_col = i
    else if ($i == "rbp" || $i == "x29") fp_col = i
    else if ($i == "ra" || $i == "x30") ra_col = i
  }
  next
}
FNR == NR && in_fde && /^[0-9a-f]+ / {
  cfa = $cfa_col
  if (!match(cfa, /^(rsp|sp|rbp|x29)\+[0-9]+$/)) next # an expression: not stepped through
  split(cfa, c, "+")
  rule = c[2] + (c[1] == "rbp" || c[1] == "x29" ? 4294967296 : 0)
  rule += (fp_col ? slot($fp_col) : 0) * 65536
  rule += (ra_col ? slot($ra_col) : 0) * 1099511627776
  ROW[NROW] = hex($1); RULE[NROW++] = rule
  next
}
FNR == NR { next }

# --- objdump -d: a call's return address is the next instruction's ---
/^[0-9a-f]+ <.*>:$/ { fn = $0; sub(/^[0-9a-f]+ </, "", fn); sub(/>:$/, "", fn); next }
/^ *[0-9a-f]+:\t/ {
  a = $1; sub(/:$/, "", a)
  if (pending != "") { at[NC] = pending; ret[NC] = hex(a); to[NC++] = pending_to; pending = "" }
  callee = ""
  if (match($0, /<[^>+]+>$/)) callee = substr($0, RSTART + 1, RLENGTH - 2)
  if ($2 ~ /^(call|callq|bl|blr)$/) { pending = hex(a); pending_to = callee }
  # what calls what, tail calls included
  if (callee != "" && callee != fn && $2 ~ /^(call|callq|bl|jmp|b)$/) edge[fn, callee] = 1
}

END {
  # the functions on the way to the targets
  n = split(targets, t, " ")
  for (i = 1; i <= n; i++) on[t[i]] = 1
  for (grew = 1; grew; ) {
    grew = 0
    for (k in edge) { split(k, e, SUBSEP); if (on[e[2]] && !on[e[1]]) { on[e[1]] = 1; grew = 1 } }
  }
  # for each call, the row in effect: the last of its function's rows (in
  # address order) at or before it
  FROW[NF_] = NROW
  for (i = 0; i < NC; i++) {
    if (targets != "" && !on[to[i]]) continue
    for (f = 0; f < NF_ && !(FLO[f] <= at[i] && at[i] < FHI[f]); f++) ;
    if (f == NF_) continue
    j = -1
    for (k = FROW[f]; k < FROW[f + 1] && ROW[k] <= at[i]; k++) j = k
    if (j >= 0 && RULE[j] % 65536 > 0) printf("@unwind[0x%x] = 0x%x;\n", ret[i], RULE[j])
  }
}
