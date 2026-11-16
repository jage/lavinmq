# top.awk: draws the reports of top.bt, one screen per interval. Each report
# is the lines from "M<TAB>time<TAB>ns<TAB>ns of the report before" to "E": the maps of top.bt as
# bpftrace prints them (0.20: "count 1, average 2, total 3", 0.25:
# "{ .count = 1, .average = 2, .total = 3 }"). Anything else goes to stderr.
#
# Variables: pid, exe, interval (s), sort (busy, block, runs, avg, max, read
# or write), io (1: with the bytes read and written per fiber), top (rows,
# 0: what fits), tty (1: redraw in place on the alternate screen), keys (1:
# lavinmq-bpf sends the keys typed, as "K<TAB>key" lines), proc (the
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

# bytes read from and written to disk so far, in counters[1..2]; 0 when unreadable
function disk(counters,    f, line, a, ok) {
  f = proc "/io"
  while ((getline line < f) > 0) {
    split(line, a, " ")
    if (a[1] == "read_bytes:") { counters[1] = a[2]; ok = 1 }
    if (a[1] == "write_bytes:") counters[2] = a[2]
  }
  close(f)
  return ok
}

function rate(bytes) {
  if (bytes < 1024) return sprintf("%.0f B/s", bytes)
  if (bytes < 1048576) return sprintf("%.1f kB/s", bytes / 1024)
  return sprintf("%.1f MB/s", bytes / 1048576)
}

function bytes(n) {
  if (n < 1024) return sprintf("%d", n)
  if (n < 1048576) return sprintf("%.1fk", n / 1024)
  if (n < 1073741824) return sprintf("%.1fM", n / 1048576)
  return sprintf("%.1fG", n / 1073741824)
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
  if (sort == "runs") return f_runs[name]
  if (sort == "avg") return f_avg[name]
  if (sort == "max") return f_max[name]
  if (sort == "block") return f_blocked[name]
  if (sort == "read") return f_read[name]
  if (sort == "write") return f_written[name]
  return f_busy[name]
}

function before(a, b) {
  return key(a) > key(b) || (key(a) == key(b) && a < b)
}

function emit(line, style) {
  if (tty && style != "") line = style sprintf("%-" screen_cols "s", substr(line, 1, screen_cols)) "\033[m"
  else if (tty) line = substr(line, 1, screen_cols) "\033[K"
  screen = screen (lines++ ? "\n" : "") line
}

# A report: the accounts of its interval, and unless paused the frame that
# draw() shows: the header lines and per fiber name the f_ arrays.
function render(    prev, dt, tid, start, part, name, n, i, total, switched, ticks, cpu, running, gone, spawned, finished, off, total_blocked, counters, disk_io) {
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

  for (name in busy) {
    total += busy[name]
    total_blocked += blocked[name]
    switched += runs[name]
  }
  alive += spawned - finished
  ticks = cpu_ticks()
  cpu = ticks >= 0 && last_ticks != "" ? sprintf("%.1f%%", (ticks - last_ticks) / hz / dt * 100) : "-"
  last_ticks = ticks >= 0 ? ticks : ""
  disk_io = "disk read -, write -"
  if (disk(counters)) {
    if (last_read != "") disk_io = sprintf("disk read %s, write %s", rate((counters[1] - last_read) / dt), rate((counters[2] - last_write) / dt))
    last_read = counters[1]; last_write = counters[2]
  }
  if (paused) return

  f_wall = wall
  head[1] = sprintf("process: cpu %s, rss %s, GC heap %s, %s", cpu, rss_mb(), heap == "" ? "-" : sprintf("%.0f MB", heap / 1048576), disk_io)
  head[2] = sprintf("fibers:  %.1f%% busy (%.1f%% blocked), %.0f runs/s, %.0f spawned/s, %.0f finished/s, %+d alive since attach",
                    total / dt / 1e7, total_blocked / dt / 1e7, switched / dt, spawned / dt, finished / dt, alive)
  if (gc[1] > 0)
    head[3] = sprintf("gc:      %d collections %s, stop-the-world %s (max %s)", gc[1], dur(gc[3]), dur(stw[3]), dur(stw_max))
  else
    head[3] = "gc:      0 collections"
  delete f_name; delete f_busy; delete f_blocked; delete f_runs; delete f_avg; delete f_max
  delete f_read; delete f_written; delete f_state
  f_n = 0
  for (name in busy) {
    f_name[++f_n] = name
    f_busy[name] = busy[name] / dt / 1e7
    f_blocked[name] = blocked[name] / dt / 1e7
    f_runs[name] = runs[name] / dt
    f_avg[name] = runs[name] ? busy[name] / runs[name] : 0
    f_max[name] = longest[name]
    f_read[name] = read[name] / dt
    f_written[name] = written[name] / dt
    f_state[name] = name in running ? "running" : runs[name] ? "active" : "sleeping"
  }
  draw()
}

# The frame, by the sort column, the rows that match the filter from the
# scroll offset on; with keys the last line of the screen tells them.
function draw(    title, name, names, n, i, j, best, limit, room) {
  if (tty) terminal()
  screen = ""; lines = 0
  title = sprintf("lavinmq-bpf top: pid %s (%s), %s, every %s s, by %s", pid, exe, f_wall, interval, sort)
  if (filter != "") title = title ", filter \"" filter "\""
  if (paused) title = title ", paused"
  emit(title); emit(head[1]); emit(head[2]); emit(head[3]); emit("")

  if (help) {
    emit(" < >  left right   sort by the column before, after")
    emit(" up down  k j      scroll a row")
    emit(" PgUp PgDn         scroll a screen")
    emit(" Home End  g G     first, last row")
    emit(" /                 filter fiber names (Enter keeps it, Esc drops it)")
    emit(" p  Space          pause, go on")
    emit(" ?  h              this help")
    emit(" q  Ctrl-C         quit")
  } else {
    emit(" BUSY% BLOCK%  RUNS/s     AVG     MAX" (io ? "  READ/s WRITE/s" : "") "  STATE     FIBER", "\033[7m")
    for (i = 1; i <= f_n; i++)
      if (filter == "" || index(tolower(f_name[i]), tolower(filter))) names[++n] = f_name[i]
    limit = top > 0 ? top : 15
    room = screen_rows - lines - (keys ? 1 : 0)
    if (tty && (top == 0 || limit > room)) limit = room
    page = limit
    if (offset > n - limit) offset = n - limit
    if (offset < 0) offset = 0
    for (i = 1; i <= n && i <= offset + limit; i++) {
      best = i
      for (j = i + 1; j <= n; j++)
        if (before(names[j], names[best])) best = j
      name = names[best]; names[best] = names[i]
      if (i <= offset) continue
      emit(sprintf("%6.1f %6.1f %7.0f %7s %7s%s  %-8s  %s", f_busy[name], f_blocked[name], f_runs[name],
                   f_runs[name] ? dur(f_avg[name]) : "-", f_max[name] ? dur(f_max[name]) : "-",
                   io ? sprintf(" %7s %7s", bytes(f_read[name]), bytes(f_written[name])) : "", f_state[name], name))
    }
  }
  if (keys) {
    while (lines < screen_rows - 1) emit("")
    if (typing) emit(" filter: " filter "_", "\033[7m")
    else if (help) emit(" ? back", "\033[7m")
    else emit(sprintf(" %d-%d of %d   < > sort   arrows scroll   / filter   p pause   ? help   q quit",
                      n ? offset + 1 : 0, offset + limit < n ? offset + limit : n, n), "\033[7m")
  }

  # The alternate screen from the first report on: what bpftrace says
  # before that (it failed to attach) stays readable.
  if (tty && !drawn++) printf "\033[?1049h\033[?25l"
  if (tty) printf "\033[H%s\033[J", screen
  else print (frames++ ? "\n" : "") screen
  fflush()
}

# A key, as lavinmq-bpf names it: a character, or up, pgdn, enter, ...
function keypress(k,    columns, n, i) {
  if (typing) {
    if (k == "enter") typing = 0
    else if (k == "esc") { typing = 0; filter = "" }
    else if (k == "bs") filter = substr(filter, 1, length(filter) - 1)
    else if (length(k) == 1) filter = filter k
    offset = 0
  } else if (k == "q") {
    if (keys) system("kill -INT 0") # as Ctrl-C does: bpftrace ends, and so the input
  } else if (k == "<" || k == ">" || k == "left" || k == "right") {
    n = split("busy block runs avg max" (io ? " read write" : ""), columns, " ")
    for (i = 1; i < n && columns[i] != sort; i++) ;
    i += (k == ">" || k == "right") ? 1 : -1
    sort = columns[i < 1 ? n : i > n ? 1 : i]
    offset = 0
  }
  else if (k == "up" || k == "k") offset--
  else if (k == "down" || k == "j") offset++
  else if (k == "pgup") offset -= page
  else if (k == "pgdn") offset += page
  else if (k == "home" || k == "g") offset = 0
  else if (k == "end" || k == "G") offset = 1e9 # draw() brings it back to the last screen
  else if (k == "/") { typing = 1; help = 0 }
  else if (k == "esc") filter = ""
  else if (k == "p" || k == " ") paused = !paused
  else if (k == "?" || k == "h") help = !help
  if (tty && drawn) draw()
}

END { if (drawn) printf "\033[?25h\033[?1049l" }

/^K\t/ { keypress(substr($0, 3)); next }

/^M\t/ {
  split($0, m, "\t")
  wall = m[2]; now = m[3] + 0; tick = m[4]
  delete busy; delete runs; delete longest; delete open; delete hog; delete hog_in
  delete blocked; delete blocked_since; delete blk; delete blk_tick; delete read; delete written
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

/^@rbytes\[/ && match($0, /\]: -?[0-9]+$/) { read[substr($0, 9, RSTART - 9)] = substr($0, RSTART + 3) + 0; next }
/^@wbytes\[/ && match($0, /\]: -?[0-9]+$/) { written[substr($0, 9, RSTART - 9)] = substr($0, RSTART + 3) + 0; next }
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
