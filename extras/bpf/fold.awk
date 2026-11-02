# fold.awk: bpftrace's dump of @stacks[comm, fiber, ustack, kstack] = count()
# to folded stacks ("thread;fiber;root;...;leaf count", root first), the input
# format of flamegraph.awk, FlameGraph's flamegraph.pl and speedscope.
# Kernel frames get a "_[k]" suffix; offsets are dropped so samples merge per
# function; unresolved addresses become "[unknown]", runs of them one frame.
# With -v frames=FILE, also writes "function<TAB>offset<TAB>leaf<TAB>count" for
# every user frame, for lines.sh to map to source lines.

# Thread and fiber names come from the process: a name cut by bpftrace's
# string limit can end inside a UTF-8 sequence, which makes the SVG invalid,
# so bytes outside ASCII become "?".
function clean(s) {
  gsub(/[^\001-\177]/, "?", s)
  return s
}

function frame(line) {
  sub(/^ +/, "", line)
  sub(/\+[0-9]+$/, "", line)
  gsub(/;/, ":", line)
  if (line ~ /^0x[0-9a-f]+$/) line = "[unknown]"
  return line
}

function emit(count,    out, i) {
  if (frames != "")
    for (i = 1; i <= nu; i++)
      if (uoff[i] != "") printf("%s\t%s\t%d\t%d\n", u[i], uoff[i], i == 1 && nk == 0, count) > frames
  out = thread
  if (fiber != "") out = out ";" fiber
  for (i = nu; i >= 1; i--) out = out ";" u[i]
  for (i = nk; i >= 1; i--) out = out ";" k[i] "_[k]"
  print out " " count
}

# no stack at all: "@stacks[thread, fiber, , ]: n"
/^@stacks\[.*, , \]: [0-9]+$/ {
  head = substr($0, 9)
  n = head
  sub(/.*: /, "", n)
  sub(/, , \]: [0-9]+$/, "", head)
  i = index(head, ", ")
  thread = substr(head, 1, i - 1)
  fiber = substr(head, i + 2)
  gsub(/;/, ":", thread); gsub(/;/, ":", fiber)
  thread = clean(thread); fiber = clean(fiber)
  nu = 1; u[1] = "[no stack]"; uoff[1] = ""; nk = 0
  emit(n)
  in_rec = 0
  next
}

/^@stacks\[/ {
  head = substr($0, 9)
  sub(/, $/, "", head)
  i = index(head, ", ")
  thread = substr(head, 1, i - 1)
  fiber = substr(head, i + 2)
  gsub(/;/, ":", thread); gsub(/;/, ":", fiber)
  thread = clean(thread); fiber = clean(fiber)
  nu = 0; nk = 0; in_kernel = 0; in_rec = 1
  next
}

!in_rec { next }

/^    / {
  f = frame($0)
  # a frame pointer walk through code built without them yields runs of junk
  if (f == "[unknown]" && (in_kernel ? k[nk] : u[nu]) == f) next
  if (in_kernel) k[++nk] = f
  else {
    u[++nu] = f
    off = ""
    if (match($0, /\+[0-9]+$/)) off = substr($0, RSTART + 1)
    uoff[nu] = off
  }
  next
}

/^, \]: [0-9]+$/ || /^\]: [0-9]+$/ {
  n = $0
  sub(/.*: /, "", n)
  emit(n)
  in_rec = 0
  next
}

/^, *$/ { in_kernel = 1; next }
