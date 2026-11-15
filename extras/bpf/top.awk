# top.awk: draws the reports of top.bt, one screen per interval. Each report
# is the lines from "M<TAB>time<TAB>ns<TAB>ns of the report before" to "E": the maps of top.bt as
# bpftrace prints them (0.20: "count 1, average 2, total 3", 0.25:
# "{ .count = 1, .average = 2, .total = 3 }"). Anything else goes to stderr.
#
# Variables: pid, exe, interval (s), sort (busy, block, runs, avg or max), top (rows,
# 0: what fits), tty (1: redraw in place on the alternate screen), proc (the
# process's /proc directory, for its CPU time and resident memory), hz (clock
# ticks per second of /proc/<pid>/stat).

function dur(ns) {
  if (ns < 1000) return sprintf("%dns", ns)
  if (ns < 1e6) return sprintf("%.0fus", ns / 1e3)
  if (ns < 1e7) return sprintf("%.2fms", ns / 1e6)
  if (ns < 1e8) return sprintf("%.1fms", ns / 1e6)
  if (ns < 1e9) return sprintf("%.0fms", ns / 1e6)
  return sprintf("%.2fs", ns / 1e9)
}

# count, average and total of a stats() value, into v[1..3]
function stats(s, v) {
  gsub(/[^0-9,-]/, "", s)
  split(s, v, ",")
}

# utime + stime in clock ticks, -1 when the process is gone
function cpu_ticks(    f, line, a) {
  f = proc "/stat"
  if ((getline line < f) <= 0) return -1
  close(f)
  sub(/^.*\) /, "", line) # the command can hold spaces and parentheses
  split(line, a, " ")
  return a[12] + a[13]
}

# bytes read from and written to disk so far, in io[1..2]; 0 when unreadable
function disk(io,    f, line, a, ok) {
  f = proc "/io"
  while ((getline line < f) > 0) {
    split(line, a, " ")
    if (a[1] == "read_bytes:") { io[1] = a[2]; ok = 1 }
    if (a[1] == "write_bytes:") io[2] = a[2]
  }
  close(f)
  return ok
}

function rate(bytes) {
  if (bytes < 1024) return sprintf("%.0f B/s", bytes)
  if (bytes < 1048576) return sprintf("%.1f kB/s", bytes / 1024)
  return sprintf("%.1f MB/s", bytes / 1048576)
}

function rss_mb(    f, line, a, mb) {
  f = proc "/status"
  mb = "-"
  while ((getline line < f) > 0)
    if (line ~ /^VmRSS:/) {
      split(line, a, " ")
      mb = sprintf("%.0f MB", a[2] / 1024)
    }
  close(f)
  return mb
}

function terminal(    cmd, s, a) {
  screen_rows = 24; screen_cols = 80
  cmd = "stty size 2> /dev/null < /dev/tty"
  if ((cmd | getline s) > 0 && split(s, a, " ") == 2 && a[1] > 0 && a[2] > 0) {
    screen_rows = a[1]; screen_cols = a[2]
  }
  close(cmd)
}

function key(name) {
  if (sort == "runs") return runs[name]
  if (sort == "avg") return runs[name] ? busy[name] / runs[name] : 0
  if (sort == "max") return longest[name]
  if (sort == "block") return blocked[name]
  return busy[name]
}

function before(a, b) {
  return key(a) > key(b) || (key(a) == key(b) && a < b)
}

function emit(line) {
  if (tty) line = substr(line, 1, screen_cols) "\033[K"
  screen = screen (lines++ ? "\n" : "") line
}

function render(    prev, dt, tid, start, part, name, names, n, i, j, best, limit, total, switched, ticks, cpu, running, gone, spawned, finished, off, total_blocked, io, disk_io) {
  prev = tick ? tick : now - interval * 1e9
  dt = (now - prev) / 1e9
  if (dt <= 0) dt = interval

  # Stretches still going on: what they took of this interval, named when
  # the fiber was sampled. Short ones are every thread's current run.
  for (name in busy) known[name] = 1
  for (tid in open) {
    start = open[tid] + 0
    part = now - (start > prev ? start : prev)
    if ((tid in hog) && hog_in[tid] == open[tid]) {
      name = hog[tid]
      known[name] = 1
    } else if (part >= 2e7)
      name = "(thread " tid ", still running)"
    else
      continue
    running[name] = 1
    if (part < 2e7) continue
    busy[name] += part
    if (now - start > longest[name]) longest[name] = now - start
    if ((tid in blk) && blk_tick[tid] == tick) blocked[name] += blk[tid]
    if (tid in blocked_since) {
      off = blocked_since[tid] + 0
      blocked[name] += now - (off > prev ? off : prev)
    }
  }

  # Fibers stay listed while they sleep, until one of their name finishes
  # with none left that were seen spawned: of those from before the tool
  # attached only the ones that run are known, and they show again then.
  for (name in spawned_by) {
    known[name] = 1
    fibers[name] += spawned_by[name]
    spawned += spawned_by[name]
  }
  for (name in finished_by) {
    fibers[name] -= finished_by[name]
    finished += finished_by[name]
    if (fibers[name] <= 0) gone[name] = 1
  }
  for (name in known)
    if (!(name in busy) && !(name in gone)) busy[name] = 0
  for (name in gone) {
    delete known[name]
    delete fibers[name]
  }

  n = 0
  for (name in busy) {
    names[++n] = name
    total += busy[name]
    total_blocked += blocked[name]
    switched += runs[name]
  }
  alive += spawned - finished
  ticks = cpu_ticks()
  cpu = ticks >= 0 && last_ticks != "" ? sprintf("%.1f%%", (ticks - last_ticks) / hz / dt * 100) : "-"
  last_ticks = ticks >= 0 ? ticks : ""
  disk_io = "disk read -, write -"
  if (disk(io)) {
    if (last_read != "") disk_io = sprintf("disk read %s, write %s", rate((io[1] - last_read) / dt), rate((io[2] - last_write) / dt))
    last_read = io[1]; last_write = io[2]
  }

  if (tty) terminal()
  screen = ""; lines = 0
  emit(sprintf("lavinmq-bpf top: pid %s (%s), %s, every %s s, by %s", pid, exe, wall, interval, sort))
  emit(sprintf("process: cpu %s, rss %s, GC heap %s, %s", cpu, rss_mb(), heap == "" ? "-" : sprintf("%.0f MB", heap / 1048576), disk_io))
  emit(sprintf("fibers:  %.1f%% busy (%.1f%% blocked), %.0f runs/s, %.0f spawned/s, %.0f finished/s, %+d alive since attach",
               total / dt / 1e7, total_blocked / dt / 1e7, switched / dt, spawned / dt, finished / dt, alive))
  if (gc[1] > 0)
    emit(sprintf("gc:      %d collections %s, stop-the-world %s (max %s)", gc[1], dur(gc[3]), dur(stw[3]), dur(stw_max)))
  else
    emit("gc:      0 collections")
  emit("")
  emit(" BUSY% BLOCK%  RUNS/s     AVG     MAX  STATE     FIBER")

  limit = top > 0 ? top : 15
  if (tty && (top == 0 || limit > screen_rows - lines)) limit = screen_rows - lines
  for (i = 1; i <= n && i <= limit; i++) {
    best = i
    for (j = i + 1; j <= n; j++)
      if (before(names[j], names[best])) best = j
    name = names[best]; names[best] = names[i]
    emit(sprintf("%6.1f %6.1f %7.0f %7s %7s  %-8s  %s", busy[name] / dt / 1e7, blocked[name] / dt / 1e7, runs[name] / dt,
                 runs[name] ? dur(busy[name] / runs[name]) : "-", longest[name] ? dur(longest[name]) : "-",
                 name in running ? "running" : runs[name] ? "active" : "sleeping", name))
  }

  if (tty) printf "\033[H%s\033[J", screen
  else print (frames++ ? "\n" : "") screen
  fflush()
}

BEGIN { if (tty) printf "\033[?1049h\033[?25l" }
END { if (tty) printf "\033[?25h\033[?1049l" }

/^M\t/ {
  split($0, m, "\t")
  wall = m[2]; now = m[3] + 0; tick = m[4]
  delete busy; delete runs; delete longest; delete open; delete hog; delete hog_in
  delete blocked; delete blocked_since; delete blk; delete blk_tick
  delete spawned_by; delete finished_by
  stw_max = 0
  stats("0,0,0", gc); stats("0,0,0", stw)
  in_report = 1
  next
}

!in_report { print > "/dev/stderr"; next }

/^E$/ { render(); in_report = 0; next }

/^@run\[/ && match($0, /\]: [{ .]*count[ =]+-?[0-9]+, [.]?average[ =]+-?[0-9]+, [.]?total[ =]+-?[0-9]+[ }]*$/) {
  fiber = substr($0, 6, RSTART - 6)
  stats(substr($0, RSTART + 3), run)
  runs[fiber] = run[1]; busy[fiber] = run[3]
  next
}

/^@max_run\[/ && match($0, /\]: -?[0-9]+$/) {
  longest[substr($0, 10, RSTART - 10)] = substr($0, RSTART + 3) + 0
  next
}

/^@blocked\[/ && match($0, /\]: -?[0-9]+$/) {
  blocked[substr($0, 10, RSTART - 10)] = substr($0, RSTART + 3) + 0
  next
}

/^@off\[[0-9]+\]: [0-9]+$/ { blocked_since[substr($1, 6, length($1) - 7)] = $2; next }
/^@blk\[[0-9]+\]: [0-9]+$/ { blk[substr($1, 6, length($1) - 7)] = $2; next }
/^@blk_tick\[[0-9]+\]: [0-9]+$/ { blk_tick[substr($1, 11, length($1) - 12)] = $2; next }
/^@in\[[0-9]+\]: [0-9]+$/ { open[substr($1, 5, length($1) - 6)] = $2; next }
/^@hog_in\[[0-9]+\]: [0-9]+$/ { hog_in[substr($1, 9, length($1) - 10)] = $2; next }
/^@hog\[[0-9]+\]: / { hog[substr($1, 6, length($1) - 7)] = substr($0, length($1) + 2); next }
/^@spawned\[/ && match($0, /\]: [0-9]+$/) { spawned_by[substr($0, 10, RSTART - 10)] = substr($0, RSTART + 3) + 0; next }
/^@finished\[/ && match($0, /\]: [0-9]+$/) { finished_by[substr($0, 11, RSTART - 11)] = substr($0, RSTART + 3) + 0; next }
/^@gc: / { stats(substr($0, 6), gc); next }
/^@stw: / { stats(substr($0, 7), stw); next }
/^@stw_max: [0-9]+$/ { stw_max = $2; next }
/^@heap: [0-9]+$/ { heap = $2; next }

{ print > "/dev/stderr" }
