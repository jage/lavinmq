# report.awk: recordings from record.bt (.trace) or profiles (.folded) to the
# JSON that report.html shows. Usage:
#   awk -f report.awk a.trace [b.folded ...] > data.json
#   awk -v mode=frames -f report.awk a.trace > frames   # for lines.sh
# For X.trace, the source lines in X.lines (from lines.sh) are used when the
# file exists. Times in the JSON are µs since the recording started. Frames
# and stacks are shared tables: a stack is a node, a node is (parent, frame).

function json(s) {
  gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/[\001-\037]/, " ", s)
  # < and >: the JSON sits in a <script> element
  gsub(/</, "\\u003c", s); gsub(/>/, "\\u003e", s)
  return "\"" s "\""
}

# Thread and fiber names come from the process and can be cut inside a UTF-8
# sequence; bytes outside ASCII become "?".
function clean(s) { gsub(/[^\001-\177]/, "?", s); return s }

function us(ns) { return sprintf("%.0f", (ns - T0) / 1000) }

function frame(l,    off) {
  sub(/^[ \t]+/, "", l)
  off = ""
  if (match(l, /\+[0-9]+$/)) { off = substr(l, RSTART + 1); l = substr(l, 1, RSTART - 1) }
  gsub(/;/, ":", l)
  if (l ~ /^0x[0-9a-f]+$/) { l = "[unknown]"; off = "" }
  # the probe's own BPF program, named after the probe and the pid
  if (l ~ /^bpf_prog_[0-9a-f]+_/) l = "bpf_prog (a probe)"
  FOFF = off
  return l
}

function fidx(name) { # fiber name
  if (!(name in FIB)) { FIB[name] = NF_; FIBN[NF_++] = name }
  return FIB[name]
}

function tidx(tid, name) {
  if (!(tid in TID)) { TID[tid] = NT; TIDV[NT] = tid; TNAME[NT++] = name }
  else if (name != "" && TNAME[TID[tid]] == "") TNAME[TID[tid]] = name
  return TID[tid]
}

function fridx(name) {
  if (!(name in FR)) { FR[name] = NFR; FRN[NFR++] = name }
  return FR[name]
}

function node(parent, fr,    k) {
  k = parent SUBSEP fr
  if (!(k in NODE)) { NODE[k] = NN; NP[NN] = parent; NF2[NN++] = fr }
  return NODE[k]
}

function add(a, s) { BUF[a] = BUF[a] (BUF[a] == "" ? "" : ",") s }

# Close the sample being read: user frames u[1..nu] and kernel k[1..nk],
# leaf first.
function flush_sample(    i, n, prev) {
  if (!in_sample) return
  in_sample = 0
  if (mode == "frames") {
    for (i = 1; i <= nu; i++) if (uoff[i] != "") printf("%s\t%s\t%d\t1\n", u[i], uoff[i], i == 1 && nk == 0)
    return
  }
  n = -1; prev = ""
  for (i = nu; i >= 1; i--) { if (u[i] == "[unknown]" && prev == "[unknown]") continue; n = node(n, fridx(u[i])); prev = u[i] }
  for (i = nk; i >= 1; i--) n = node(n, fridx(k[i] "_[k]"))
  if (n < 0) n = node(-1, fridx("[no stack]"))
  add("samples", s_t "," s_time "," s_f "," n ",1")
  NS++
}

function begin_file() {
  if (NR > 1) end_file()
  split("", BUF); split("", FIB); split("", FIBN); split("", TID); split("", TIDV); split("", TNAME)
  split("", FR); split("", FRN); split("", NODE); split("", NP); split("", NF2); split("", META)
  split("", OBJ); split("", OC); split("", OF); split("", OL); split("", ONCPU); split("", RUNS); split("", MAXR); split("", SPAWN); split("", FIN); split("", LJ); split("", nl)
  NF_ = NT = NFR = NN = NS = 0; T0 = ""; TEND = ""; kind = "folded"; in_sample = 0
  file = FILENAME
  lf = file; sub(/\.trace$/, ".lines", lf)
  if (mode != "frames" && lf != file)
    while ((getline l < lf) > 0) {
      split(l, a, "\t")
      if (++nl[a[1]] > 15) continue # rows are sorted by samples
      LJ[a[1]] = LJ[a[1]] (LJ[a[1]] == "" ? "" : ",") "[" json(a[2]) "," json(a[3]) "," (a[4] + 0) "]"
    }
}

function end_file(    i, s, name, sep, f) {
  flush_sample()
  if (mode == "frames") return
  name = file; sub(/.*\//, "", name); sub(/\.(trace|folded)$/, "", name)
  printf("%s{\"name\":%s,\"kind\":%s", NOUT++ ? ",\n" : "[", json(name), json(kind))
  for (i in META) printf(",%s:%s", json(i), json(META[i]))
  if (T0 != "" && TEND != "") printf(",\"duration_us\":%s", us(TEND))
  for (f in ONCPU) fidx(f)
  for (f in SPAWN) fidx(f)
  printf(",\n\"threads\":[")
  for (i = 0; i < NT; i++) printf("%s[%s,%s]", i ? "," : "", json(TIDV[i]), json(TNAME[i]))
  printf("],\n\"fibers\":[")
  for (i = 0; i < NF_; i++) printf("%s%s", i ? "," : "", json(FIBN[i]))
  printf("],\n\"fstats\":[")
  sep = ""
  for (f in ONCPU) { printf("%s[%d,%s,%d,%s,%d,%d]", sep, fidx(f), sprintf("%.0f", ONCPU[f] / 1000), RUNS[f], sprintf("%.0f", MAXR[f] / 1000), SPAWN[f], FIN[f]); sep = "," }
  for (f in SPAWN) if (!(f in ONCPU)) { printf("%s[%d,0,0,0,%d,%d]", sep, fidx(f), SPAWN[f], FIN[f]); sep = "," }
  printf("],\n\"objects\":[")
  sep = ""
  for (f in OBJ) { printf("%s[%s,%d,%d,%d]", sep, json(f), OC[f], OF[f], OL[f]); sep = "," }
  printf("],\n\"frames\":[")
  for (i = 0; i < NFR; i++) printf("%s%s", i ? ",\n" : "", json(FRN[i]))
  printf("],\n\"lines\":{")
  sep = ""
  for (i = 0; i < NFR; i++) if (FRN[i] in LJ) { printf("%s\"%d\":[%s]", sep, i, LJ[FRN[i]]); sep = ",\n" }
  printf("},\n\"nodes\":[")
  for (i = 0; i < NN; i++) printf("%s%d,%d", i ? "," : "", NP[i], NF2[i])
  printf("]")
  split("runs idle gc short samples", keys, " ")
  for (i = 1; i <= 5; i++) printf(",\n%s:[%s]", json(keys[i]), BUF[keys[i]])
  printf("}")
}

FNR == 1 { begin_file() }

# --- .folded: "thread;frame;...;leaf count" ---
kind == "folded" && /^[^\t#@][^\t]* [0-9]+$/ && !/^(B|N|R|I|G|S|E|U|K)\t/ {
  c = $NF; st = substr($0, 1, length($0) - length(c) - 1)
  m = split(st, f, ";")
  if (mode == "frames") next
  t = tidx(clean(f[1]), clean(f[1]))
  n = -1
  for (i = 2; i <= m; i++) n = node(n, fridx(f[i]))
  if (n < 0) n = node(-1, fridx("[no stack]"))
  add("samples", t ",-1,-1," n "," c)
  NS += c
  next
}

# --- .trace ---
/^# [a-z_]+\t/ { l = substr($0, 3); split(l, a, "\t"); META[a[1]] = clean(substr(l, length(a[1]) + 2)); next }
/^B\t/ { kind = "trace"; split($0, a, "\t"); T0 = a[2]; next }
/^E\t/ { flush_sample(); split($0, a, "\t"); TEND = a[2]; next }
/^N\t/ { split($0, a, "\t"); tidx(a[2], clean(a[3])); next }
/^Lost [0-9]+ events$/ { flush_sample(); META["lost"] = META["lost"] + $2; next }
# Events still arriving after the end (bpftrace detaching) are left out.
/^(R|I|S)\t/ && TEND != "" { split($0, a, "\t"); if (a[3] + 0 > TEND + 0) { flush_sample(); skip = 1; next } }
/^G\t/ && TEND != "" { split($0, a, "\t"); if (a[2] + 0 > TEND + 0) { flush_sample(); next } }
/^R\t/ {
  flush_sample(); split($0, a, "\t")
  if (mode != "frames") add("runs", tidx(a[2], "") "," us(a[3]) "," sprintf("%.0f", a[4] / 1000) "," sprintf("%.0f", a[5] / 1000) "," fidx(clean(a[7])))
  next
}
/^I\t/ { flush_sample(); split($0, a, "\t"); if (mode != "frames") add("idle", tidx(a[2], "") "," us(a[3]) "," sprintf("%.0f", a[4] / 1000)); next }
/^G\t/ {
  flush_sample(); split($0, a, "\t")
  if (mode != "frames") add("gc", us(a[2]) "," sprintf("%.0f", a[3] / 1000) "," (a[4] + 0 > 0 ? us(a[4]) : -1) "," sprintf("%.0f", a[5] / 1000) "," sprintf("%.0f", a[6] / 1024) "," tidx(a[7], ""))
  next
}
/^S\t/ {
  flush_sample(); split($0, a, "\t")
  in_sample = 1; part = ""; nu = nk = 0
  if (mode != "frames") { s_t = tidx(a[2], clean(a[4])); s_time = us(a[3]); s_f = fidx(clean(a[5])) }
  next
}
# (a regex alternative that is empty matches every line in mawk)
skip && (/^[UK]$/ || /^[ \t]/ || /^$/) { next }
{ skip = 0 }
in_sample && /^U$/ { part = "u"; next }
in_sample && /^K$/ { part = "k"; next }
in_sample && /^[ \t]+[^ \t]/ {
  fr = frame($0)
  if (part == "u") { u[++nu] = fr; uoff[nu] = FOFF } else if (part == "k") k[++nk] = fr
  next
}
in_sample && /^$/ { next }
/^@[a-z_]+\[.*\]: -?[0-9]+$/ {
  flush_sample()
  v = $NF; mp = $0; sub(/\[.*/, "", mp); key = $0; sub(/^@[a-z_]+\[/, "", key); sub(/\]: -?[0-9]+$/, "", key)
  key = clean(key)
  if (mp == "@on_cpu") ONCPU[key] = v
  else if (mp == "@runs") RUNS[key] = v
  else if (mp == "@max_run") MAXR[key] = v
  else if (mp == "@spawned") SPAWN[key] = v
  else if (mp == "@finished") FIN[key] = v
  else if (mp == "@created") { OBJ[key] = 1; OC[key] = v }
  else if (mp == "@finalized") { OBJ[key] = 1; OF[key] = v }
  else if (mp == "@live_delta") { OBJ[key] = 1; OL[key] = v }
  else if (mp == "@short" && mode != "frames") { split(key, kk, ", "); add("short", tidx(kk[1], "") "," us(kk[2] * 10000000) "," sprintf("%.0f", v / 1000)) }
  next
}
{ flush_sample() }

END {
  if (NR == 0) { print "report.awk: no input" > "/dev/stderr"; exit 1 }
  end_file()
  if (mode != "frames") print "]"
}
