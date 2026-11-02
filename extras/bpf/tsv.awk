# tsv.awk: turns the scripts' output under FORMAT=tsv into tab-separated
# rows on stdout, header first; everything else (banners, histograms) goes
# to stderr. The scripts tag what they print:
#   H<TAB>...   the header row
#   T<TAB>...   an event row
#   S<TAB>...   an event row that a user stack may follow, as indented frame
#               lines (leaf first); they become its last column, root first,
#               ";" between frames
#   M<TAB>time  the start of an interval's map dumps: every following
#               "@map[key]: value" becomes "time  map  key  value"; under an
#               event header (stalls, evloop) "@max_gap_ms[tid, thread]: ns"
#               becomes an interval_max row of the same shape as the events

function flush() {
  if (row != "") {
    print row (stacked ? "\t" stack : "")
    fflush()
  }
  row = ""; stack = ""; stacked = 0
}

/^H\t/ { flush(); print substr($0, 3); fflush(); events = $0 ~ /\tevent\t/; next }
/^T\t/ { flush(); row = substr($0, 3); next }
/^S\t/ { flush(); row = substr($0, 3); stacked = 1; next }
/^M\t/ { flush(); t = substr($0, 3); next }

stacked && /^    / {
  f = $0
  sub(/^ +/, "", f)
  gsub(/;/, ":", f)
  stack = stack == "" ? f : f ";" stack
  next
}

# "@map[key]: value" or "@map: value", from print() after an M line
t != "" && /^@[A-Za-z_][A-Za-z0-9_]*(\[.*\])?: -?[0-9]+$/ {
  flush()
  value = $0; sub(/.*: /, "", value)
  name = $0; sub(/: -?[0-9]+$/, "", name); sub(/^@/, "", name)
  key = ""
  if (match(name, /\[.*\]$/)) {
    key = substr(name, RSTART + 1, RLENGTH - 2)
    name = substr(name, 1, RSTART - 1)
  }
  gsub(/\t/, " ", key)
  if (events) {
    if (name == "max_gap_ms" && (i = index(key, ", ")))
      print t "\tinterval_max\t" substr(key, 1, i - 1) "\t" substr(key, i + 2) "\t" int(value / 1000) "\t\t\t"
  } else
    print t "\t" name "\t" key "\t" value
  fflush()
  next
}

/^$/ { next }

{ flush(); print > "/dev/stderr"; fflush("/dev/stderr") }

END { flush() }
