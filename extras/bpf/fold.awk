# fold.awk: bpftrace's dump of @stacks[comm, fiber, ustack, kstack] = count()
# to folded stacks ("thread;fiber;root;...;leaf count", root first), the input
# format of flamegraph.awk, FlameGraph's flamegraph.pl and speedscope.
# Kernel frames get a "_[k]" suffix; offsets are dropped so samples merge per
# function; unresolved addresses become "[unknown]", runs of them one frame.

function frame(line) {
  sub(/^ +/, "", line)
  sub(/\+[0-9]+$/, "", line)
  gsub(/;/, ":", line)
  if (line ~ /^0x[0-9a-f]+$/) line = "[unknown]"
  return line
}

function emit(count,    out, i) {
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
  nu = 1; u[1] = "[no stack]"; nk = 0
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
  nu = 0; nk = 0; in_kernel = 0; in_rec = 1
  next
}

!in_rec { next }

/^    / {
  f = frame($0)
  # a frame pointer walk through code built without them yields runs of junk
  if (f == "[unknown]" && (in_kernel ? k[nk] : u[nu]) == f) next
  if (in_kernel) k[++nk] = f
  else u[++nu] = f
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
