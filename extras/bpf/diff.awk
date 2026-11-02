# diff.awk: merges two folded profiles into "stack before after" lines, the
# input of flamegraph.awk -v diff=1. The thread name (the first frame) is
# dropped, as it differs between runs, unless -v keep_threads=1.
#   awk -f diff.awk before.folded after.folded | LC_ALL=C sort

FNR == 1 { f++ }

/ [0-9]+$/ {
  n = $NF
  s = substr($0, 1, length($0) - length(n) - 1)
  if (!keep_threads && index(s, ";")) s = substr(s, index(s, ";") + 1)
  c[s, f] += n
  stacks[s] = 1
}

END {
  if (f != 2) { print "diff.awk: needs two folded profiles" > "/dev/stderr"; exit 1 }
  for (s in stacks) print s " " (c[s, 1] + 0) " " (c[s, 2] + 0)
}
