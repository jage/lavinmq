# top.awk: draws the reports of top.bt, one screen per interval. Each report
# is the lines from "M<TAB>time<TAB>ns<TAB>ns of the report before" to "E": the maps of top.bt as
# bpftrace prints them (0.20: "count 1, average 2, total 3", 0.25:
# "{ .count = 1, .average = 2, .total = 3 }"). Anything else goes to stderr.
#
# Variables: pid, exe, interval (s), sort (busy, block, runs, avg, max, wait,
# wmax, read or write), wait (1: with the time fibers waited for a thread),
# io (1: with the bytes read and written per fiber), top (rows,
# 0: what fits), window (reports to sum, 1 to 60), cumulative (1: sum all
# since attach), tty (1: redraw in place on the alternate screen), keys (1:
# lavinmq-bpf sends the keys typed, as "K<TAB>key" lines, how far it is
# as "S<TAB>status" and "W<TAB>0" when there is no WAIT after all), proc (the
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
  if (sort == "wait") return f_wait[name]
  if (sort == "wmax") return f_wait_max[name]
  if (sort == "read") return f_read[name]
  if (sort == "write") return f_written[name]
  return f_busy[name]
}

function before(a, b) {
  return sort_key[a] > sort_key[b] || (sort_key[a] == sort_key[b] && a < b)
}

# names[lo..hi] in the order of before(), by their sort_key
function sort_names(names, lo, hi,    i, j, pivot, t) {
  if (lo >= hi) return
  pivot = names[int((lo + hi) / 2)]
  i = lo; j = hi
  while (i <= j) {
    while (before(names[i], pivot)) i++
    while (before(pivot, names[j])) j--
    if (i <= j) { t = names[i]; names[i] = names[j]; names[j] = t; i++; j-- }
  }
  sort_names(names, lo, j)
  sort_names(names, i, hi)
}

function emit(line, style) {
  if (tty && lines >= screen_rows - reserved) return
  sub(/ +$/, "", line)
  if (tty && style != "") line = style sprintf("%-" screen_cols "s", substr(line, 1, screen_cols)) "\033[m"
  else if (tty) line = substr(line, 1, screen_cols) "\033[K"
  screen = screen (lines++ ? "\n" : "") line
}

# A report: the figures of its interval go into the ring of the last RING
# reports (h_ arrays, by report and name) and into the totals since attach
# (c_ arrays), for build() to sum a window of.
function render(    prev, dt, tid, start, part, name, names, gone, spawned, finished, off, counters, r, old, a, n, i) {
  prev = tick ? tick : now - interval * 1e9
  dt = (now - prev) / 1e9
  if (dt <= 0) dt = interval

  # Stretches still going on: what they took of this interval, named when
  # the fiber was sampled. Short ones are every thread's current run.
  delete is_running
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
    is_running[name] = 1
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
  alive += spawned - finished

  r = ++reports
  delete listed
  for (name in busy) {
    listed[name] = 1
    if (!(busy[name] || runs[name] || read[name] || written[name])) continue
    names = names (names == "" ? "" : SUBSEP) name
    h_busy[r, name] = busy[name]; c_busy[name] += busy[name]
    h_blocked[r, name] = blocked[name]; c_blocked[name] += blocked[name]
    h_runs[r, name] = runs[name]; c_runs[name] += runs[name]
    h_read[r, name] = read[name]; c_read[name] += read[name]
    h_written[r, name] = written[name]; c_written[name] += written[name]
    h_max[r, name] = longest[name]
    if (longest[name] > c_max[name]) c_max[name] = longest[name]
    if (!waits[name]) continue
    h_waits[r, name] = waits[name]; c_waits[name] += waits[name]
    h_waited[r, name] = waited[name]; c_waited[name] += waited[name]
    h_wait_max[r, name] = wait_longest[name]
    if (wait_longest[name] > c_wait_max[name]) c_wait_max[name] = wait_longest[name]
  }
  r_names[r] = names
  names = ""
  for (name in run_hist) {
    h_run_hist[r, name] = run_hist[name]; c_run_hist[name] += run_hist[name]
    names = names "\n" name
  }
  r_run_hist[r] = names
  names = ""
  for (name in wait_hist) {
    h_wait_hist[r, name] = wait_hist[name]; c_wait_hist[name] += wait_hist[name]
    names = names "\n" name
  }
  r_wait_hist[r] = names
  # Where fibers blocked, once their names are known: told when the stretch
  # ends, in this report or a later one. Not from an earlier one: the
  # address may be another fiber's by now.
  names = ""
  for (name in pending) {
    split(name, a, SUBSEP)
    if (!(a[1] in name_of)) continue
    i = name_of[a[1]] SUBSEP a[2]
    if (!((r, i) in h_stacks)) names = names "\n" i
    h_stacks[r, i] += pending[name]; c_stacks[i] += pending[name]
    delete pending[name]
  }
  r_stacks[r] = names
  r_dt[r] = dt; c_dt += dt
  r_spawned[r] = spawned; c_spawned += spawned
  r_finished[r] = finished; c_finished += finished
  r_gc[r] = gc[1]; c_gc += gc[1]
  r_gc_ns[r] = gc[3]; c_gc_ns += gc[3]
  r_stw_ns[r] = stw[3]; c_stw_ns += stw[3]
  r_stw_max[r] = stw_max
  if (stw_max > c_stw_max) c_stw_max = stw_max
  r_ticks[r] = cpu_ticks()
  r_disk[r] = disk(counters); r_disk_read[r] = counters[1]; r_disk_write[r] = counters[2]
  if (r == 1) since = wall
  old = r - RING
  if (old > 1) { # the first report stays: the totals' process counters start there
    n = split(r_names[old], a, SUBSEP)
    for (i = 1; i <= n; i++) {
      delete h_busy[old, a[i]]; delete h_blocked[old, a[i]]; delete h_runs[old, a[i]]
      delete h_read[old, a[i]]; delete h_written[old, a[i]]; delete h_max[old, a[i]]
      delete h_waits[old, a[i]]; delete h_waited[old, a[i]]; delete h_wait_max[old, a[i]]
    }
    n = split(r_run_hist[old], a, "\n")
    for (i = 1; i <= n; i++) delete h_run_hist[old, a[i]]
    n = split(r_wait_hist[old], a, "\n")
    for (i = 1; i <= n; i++) delete h_wait_hist[old, a[i]]
    n = split(r_stacks[old], a, "\n")
    for (i = 1; i <= n; i++) delete h_stacks[old, a[i]]
    delete r_run_hist[old]; delete r_wait_hist[old]; delete r_stacks[old]
    delete r_names[old]; delete r_dt[old]; delete r_spawned[old]; delete r_finished[old]
    delete r_gc[old]; delete r_gc_ns[old]; delete r_stw_ns[old]; delete r_stw_max[old]
    delete r_ticks[old]; delete r_disk[old]; delete r_disk_read[old]; delete r_disk_write[old]
  }
  if (paused) return
  build()
  draw()
}

# The frame that draw() shows, the header lines and per fiber name the f_
# arrays: the last `window` reports summed, or with `cumulative` all of them.
function build(    r, from, base, i, k, n, a, name, dt, pdt, spawned, finished, collections, gc_ns, stw_ns, stw_longest, total, total_blocked, switched, cpu, disk_io, w_busy, w_blocked, w_runs, w_read, w_written, w_max, w_waits, w_waited, w_wait_max) {
  r = reports
  from = r - window + 1
  if (cumulative || from < 1) from = 1
  f_from = from
  if (cumulative) {
    for (name in c_busy) {
      w_busy[name] = c_busy[name]; w_blocked[name] = c_blocked[name]; w_runs[name] = c_runs[name]
      w_read[name] = c_read[name]; w_written[name] = c_written[name]; w_max[name] = c_max[name]
      w_waits[name] = c_waits[name]; w_waited[name] = c_waited[name]; w_wait_max[name] = c_wait_max[name]
    }
    dt = c_dt; spawned = c_spawned; finished = c_finished
    collections = c_gc; gc_ns = c_gc_ns; stw_ns = c_stw_ns; stw_longest = c_stw_max
  } else
    for (i = from; i <= r; i++) {
      dt += r_dt[i]; spawned += r_spawned[i]; finished += r_finished[i]
      collections += r_gc[i]; gc_ns += r_gc_ns[i]; stw_ns += r_stw_ns[i]
      if (r_stw_max[i] > stw_longest) stw_longest = r_stw_max[i]
      n = split(r_names[i], a, SUBSEP)
      for (k = 1; k <= n; k++) {
        name = a[k]
        w_busy[name] += h_busy[i, name]; w_blocked[name] += h_blocked[i, name]; w_runs[name] += h_runs[i, name]
        w_read[name] += h_read[i, name]; w_written[name] += h_written[i, name]
        if (h_max[i, name] > w_max[name]) w_max[name] = h_max[i, name]
        if (!((i, name) in h_waits)) continue
        w_waits[name] += h_waits[i, name]; w_waited[name] += h_waited[i, name]
        if (h_wait_max[i, name] > w_wait_max[name]) w_wait_max[name] = h_wait_max[i, name]
      }
    }

  # The process's counters, against those at the report before the window:
  # there is none before the first.
  base = from - 1; pdt = dt
  if (base < 1) { base = 1; pdt = dt - r_dt[1] }
  cpu = "-"; disk_io = "disk read -, write -"
  if (pdt > 0) {
    if (r_ticks[r] >= 0 && r_ticks[base] >= 0) cpu = sprintf("%.1f%%", (r_ticks[r] - r_ticks[base]) / hz / pdt * 100)
    if (r_disk[r] && r_disk[base])
      disk_io = sprintf("disk read %s, write %s", rate((r_disk_read[r] - r_disk_read[base]) / pdt), rate((r_disk_write[r] - r_disk_write[base]) / pdt))
  }

  delete f_name; delete f_busy; delete f_blocked; delete f_runs; delete f_avg; delete f_max
  delete f_read; delete f_written; delete f_state; delete f_waits; delete f_wait; delete f_wait_max
  f_n = 0
  for (name in listed) w_busy[name] += 0
  for (name in w_busy) {
    f_name[++f_n] = name
    f_busy[name] = w_busy[name] / dt / 1e7
    f_blocked[name] = w_blocked[name] / dt / 1e7
    f_runs[name] = w_runs[name] / dt
    f_avg[name] = w_runs[name] ? w_busy[name] / w_runs[name] : 0
    f_max[name] = w_max[name]
    f_waits[name] = w_waits[name]
    f_wait[name] = w_waits[name] ? w_waited[name] / w_waits[name] : 0
    f_wait_max[name] = w_wait_max[name]
    f_read[name] = w_read[name] / dt
    f_written[name] = w_written[name] / dt
    f_state[name] = name in is_running ? "running" : !(name in listed) ? "gone" : ((r, name) in h_runs) && h_runs[r, name] ? "active" : "sleeping"
    total += w_busy[name]; total_blocked += w_blocked[name]; switched += w_runs[name]
  }
  f_wall = wall
  f_span = cumulative ? sprintf(", since %s (%.0f s)", since, dt) : window > 1 ? sprintf(", last %.0f s", dt) : ""
  head[1] = sprintf("process: cpu %s, rss %s, GC heap %s, %s", cpu, rss_mb(), heap == "" ? "-" : sprintf("%.0f MB", heap / 1048576), disk_io)
  head[2] = sprintf("fibers:  %.1f%% busy (%.1f%% blocked), %.0f runs/s, %.0f spawned/s, %.0f finished/s, %+d alive since attach",
                    total / dt / 1e7, total_blocked / dt / 1e7, switched / dt, spawned / dt, finished / dt, alive)
  if (collections > 0)
    head[3] = sprintf("gc:      %d collections %s, stop-the-world %s (max %s)", collections, dur(gc_ns), dur(stw_ns), dur(stw_longest))
  else
    head[3] = "gc:      0 collections"
}

# 2^b us in ns (busybox awk can come without ^)
function us(b,    v) {
  for (v = 1000; b > 0; b--) v *= 2
  return v
}

# One histogram of one fiber as lines in out[1..]: of its keys name, 0 to
# name, 39 (powers of two, us) in the frame's reports. Returns their number.
function histogram(title, name, kept, total, out,    counts, i, b, lo, hi, most, n, bar) {
  lo = -1
  for (b = 0; b < 40; b++) {
    if (cumulative) counts[b] = total[name, b]
    else for (i = f_from; i <= reports; i++)
      if ((i, name, b) in kept) counts[b] += kept[i, name, b]
    if (!counts[b]) continue
    if (lo < 0) lo = b
    hi = b
    if (counts[b] > most) most = counts[b]
  }
  out[++n] = sprintf(" %-21s %8s", title, "count")
  if (lo < 0) { out[++n] = "   none"; return n }
  for (b = lo; b <= hi; b++) {
    if (!counts[b] && !counts[b + 1] && !counts[b + 2]) { # a gap: one line for it
      while (!counts[b + 1]) b++
      out[++n] = "     ..."
      continue
    }
    bar = sprintf("%" int(counts[b] / most * 20 + 0.5) "s", "")
    gsub(/ /, "#", bar)
    out[++n] = sprintf(" %7s to %-7s %10d %s", b ? dur(us(b)) : "0", dur(us(b + 1)), counts[b], bar)
  }
  return n
}

# One fiber name: its row spelled out, how long its runs and its waits
# were, and where in the kernel it blocked.
function detail_view(name,    r, w, nr, nw, i, j, n, a, parts, stacks, order, best, total, k) {
  emit(" " name "  (" (name in f_state ? f_state[name] : "gone") ")", "\033[1m")
  if (name in f_busy) {
    emit(sprintf(" busy %.1f%%  blocked %.1f%%  %.0f runs/s  avg %s  max %s", f_busy[name], f_blocked[name], f_runs[name],
                 f_runs[name] ? dur(f_avg[name]) : "-", f_max[name] ? dur(f_max[name]) : "-"))
    emit((wait ? sprintf(" waited avg %s  max %s  ", f_waits[name] ? dur(f_wait[name]) : "-", f_waits[name] ? dur(f_wait_max[name]) : "-") : " ") \
         (io ? sprintf("read %s/s  written %s/s", bytes(f_read[name]), bytes(f_written[name])) : ""))
  }
  emit("")
  if (cumulative) {
    for (k in c_stacks) {
      split(k, parts, SUBSEP)
      if (parts[1] == name) stacks[parts[2]] = c_stacks[k]
    }
  } else
    for (i = f_from; i <= reports; i++) {
      n = split(r_stacks[i], a, "\n")
      for (j = 1; j <= n; j++) {
        split(a[j], parts, SUBSEP)
        if (a[j] != "" && parts[1] == name) stacks[parts[2]] += h_stacks[i, a[j]]
      }
    }
  n = 0
  for (k in stacks) { order[++n] = k; total += stacks[k] }
  emit(" blocked off CPU in the kernel, innermost first")
  if (!n) emit("   nowhere")
  for (i = 1; i <= n && (!tty || i <= 5); i++) {
    best = i
    for (j = i + 1; j <= n; j++)
      if (stacks[order[j]] > stacks[order[best]]) best = j
    k = order[best]; order[best] = order[i]
    emit(sprintf(" %7s %5.1f%%  %s", dur(stacks[k]), stacks[k] / total * 100, k == "" ? "(no stack)" : k))
  }
  emit("")
  nr = histogram("ran for", name, h_run_hist, c_run_hist, r)
  if (wait) nw = histogram("waited for a thread", name, h_wait_hist, c_wait_hist, w)
  if (nw && (!tty || screen_cols >= 104)) {
    for (i = 1; i <= nr || i <= nw; i++) emit(sprintf("%-52s%s", r[i], w[i]))
  } else {
    for (i = 1; i <= nr; i++) emit(r[i])
    if (nw) emit("")
    for (i = 1; i <= nw; i++) emit(w[i])
  }
}

# The frame, by the sort column, the rows that match the filter from the
# scroll offset on; with keys the last line of the screen tells them. Or
# the view of the selected fiber.
function draw(    title, name, names, n, i, limit, room, rank, target) {
  if (tty) terminal()
  screen = ""; lines = 0; reserved = keys ? 1 : 0
  if (!reports) title = sprintf("lavinmq-bpf top: pid %s (%s), %s", pid, exe, status)
  else title = sprintf("lavinmq-bpf top: pid %s (%s), %s, every %s s%s, by %s", pid, exe, f_wall, interval, f_span, sort)
  if (filter != "") title = title ", filter \"" filter "\""
  if (paused) title = title ", paused"
  emit(title); emit(head[1]); emit(head[2]); emit(head[3]); emit("")

  if (help) {
    emit(" up down  k j      select a fiber")
    emit(" PgUp PgDn         a screen up, down")
    emit(" Home End  g G     the first, last")
    emit(" Enter             the selected fiber alone: how long it ran and waited, where it blocked")
    emit(" < >  left right   sort by the column before, after")
    emit(" + -               sum a longer, shorter time: the last 1, 2, 5, 10, 30 or 60 reports")
    emit(" c                 sum all since attach, and back")
    emit(" /                 filter fiber names (Enter keeps it, Esc drops it)")
    emit(" p  Space          pause, go on")
    emit(" Esc               back; drop the selection and the filter")
    emit(" ?  h              this help")
    emit(" q  Ctrl-C         quit")
  } else if (detail != "") {
    detail_view(detail)
  } else {
    emit(" BUSY% BLOCK%  RUNS/s     AVG     MAX" (wait ? "    WAIT    WMAX" : "") (io ? "  READ/s WRITE/s" : "") "  STATE     FIBER", "\033[7m")
    delete sort_key
    for (i = 1; i <= f_n; i++)
      if (filter == "" || index(tolower(f_name[i]), tolower(filter))) {
        names[++n] = f_name[i]
        sort_key[f_name[i]] = key(f_name[i])
      }
    limit = top > 0 ? top : 15
    room = screen_rows - lines - reserved
    if (tty && (top == 0 || limit > room)) limit = room
    page = limit

    # The selection is a name: its row moves as the order changes. A move
    # goes from where it is now, and scrolls to keep it on the screen.
    if (selected != "" && !(selected in f_busy)) selected = ""
    sort_names(names, 1, n)
    if (selected != "" || move) {
      for (i = 1; i <= n; i++)
        if (names[i] == selected) rank = i
      target = rank + move
      if (target > n) target = n
      if (target < 1) target = n ? 1 : 0
      if (move && target) {
        if (target <= offset) offset = target - 1
        if (target > offset + limit) offset = target - limit
      }
    }
    move = 0
    if (offset > n - limit) offset = n - limit
    if (offset < 0) offset = 0
    if (target) selected = names[target]
    for (i = offset + 1; i <= n && i <= offset + limit; i++) {
      name = names[i]
      emit(sprintf("%6.1f %6.1f %7.0f %7s %7s%s%s  %-8s  %s", f_busy[name], f_blocked[name], f_runs[name],
                   f_runs[name] ? dur(f_avg[name]) : "-", f_max[name] ? dur(f_max[name]) : "-",
                   !wait ? "" : f_waits[name] ? sprintf(" %7s %7s", dur(f_wait[name]), dur(f_wait_max[name])) : "       -       -",
                   io ? sprintf(" %7s %7s", bytes(f_read[name]), bytes(f_written[name])) : "", f_state[name], name),
           tty && name == selected ? "\033[1;4m" : "")
    }
  }
  if (keys) {
    while (lines < screen_rows - 1) emit("")
    reserved = 0
    if (typing) emit(" filter: " filter "_", "\033[7m")
    else if (help) emit(" ? back", "\033[7m")
    else if (detail != "") emit(" Esc back  +- time  c total  p pause  ? help  q quit", "\033[7m")
    else emit(sprintf(" %d-%d of %d  arrows, Enter: one fiber  <> sort  +- time  c total  / filter  p pause  ? help  q quit",
                      n ? offset + 1 : 0, offset + limit < n ? offset + limit : n, n), "\033[7m")
  }

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
    n = split("busy block runs avg max" (wait ? " wait wmax" : "") (io ? " read write" : ""), columns, " ")
    for (i = 1; i < n && columns[i] != sort; i++) ;
    i += (k == ">" || k == "right") ? 1 : -1
    sort = columns[i < 1 ? n : i > n ? 1 : i]
    offset = 0
  }
  else if (detail != "" && (k == "esc" || k == "enter")) detail = ""
  else if (k == "enter") detail = selected
  else if (k == "up" || k == "k") move -= 1
  else if (k == "down" || k == "j") move += 1
  else if (k == "pgup") move -= page
  else if (k == "pgdn") move += page
  else if (k == "home" || k == "g") move = -1e9
  else if (k == "end" || k == "G") move = 1e9
  else if (k == "+" || k == "=" || k == "-") {
    n = split("1 2 5 10 30 60", columns, " ")
    for (i = 1; i < n && columns[i] < window; i++) ;
    i += k == "-" ? -1 : 1
    window = columns[i < 1 ? 1 : i > n ? n : i]
    cumulative = 0
    if (reports) build()
  } else if (k == "c") {
    cumulative = !cumulative
    if (reports) build()
  }
  else if (k == "/") { typing = 1; help = 0 }
  else if (k == "esc") { filter = ""; selected = "" }
  else if (k == "p" || k == " ") paused = !paused
  else if (k == "?" || k == "h") help = !help
  if (tty) draw()
}

# What the tools say besides reports: on a terminal kept until the screen
# is given back, and the last of it shown while there is no report yet.
function message(line) {
  if (!tty) { print line > "/dev/stderr"; return }
  messages[++n_messages] = line
}

BEGIN {
  RING = 61
  if (window < 1) window = 1
  if (window > RING - 1) window = RING - 1
  status = "starting"
  head[1] = head[2] = head[3] = ""
  if (tty) { printf "\033[?1049h\033[?25l"; draw() }
}

END {
  if (!tty) exit
  printf "\033[?25h\033[?1049l"
  for (i = 1; i <= n_messages; i++) print messages[i] > "/dev/stderr"
}

/^K\t/ { keypress(substr($0, 3)); next }

# no WAIT after all: this Crystal has nothing to probe for it
/^W\t/ { wait = substr($0, 3) + 0; if (!wait && sort ~ /^w(ait|max)$/) sort = "busy"; next }

# how far lavinmq-bpf got, before the first report
/^S\t/ { status = substr($0, 3); if (tty && !reports) draw(); next }

/^M\t/ {
  split($0, m, "\t")
  wall = m[2]; now = m[3] + 0; tick = m[4]
  delete busy; delete runs; delete longest; delete open; delete hog; delete hog_in
  delete blocked; delete blocked_since; delete blk; delete blk_tick; delete read; delete written
  delete waits; delete waited; delete wait_longest; delete run_hist; delete wait_hist
  stack_of = ""; delete name_of
  delete spawned_by; delete finished_by
  stw_max = 0
  stats("0,0,0", gc); stats("0,0,0", stw)
  in_report = 1
  next
}

# top.bt's first line: it runs, though not all of its probes yet
/^top: pid / && tty { status = "waiting for the first report"; draw(); next }

!in_report { message($0); next }

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

/^@waited\[/ && match($0, /\]: [{ .]*count[ =]+-?[0-9]+, [.]?average[ =]+-?[0-9]+, [.]?total[ =]+-?[0-9]+[ }]*$/) {
  fiber = substr($0, 9, RSTART - 9)
  stats(substr($0, RSTART + 3), run)
  waits[fiber] = run[1]; waited[fiber] = run[3]
  next
}

/^@wait_max\[/ && match($0, /\]: -?[0-9]+$/) {
  wait_longest[substr($0, 11, RSTART - 11)] = substr($0, RSTART + 3) + 0
  next
}

# @runs_of[name, power of two]: count, and @waits_of
/^@runs_of\[/ && match($0, /, [0-9]+\]: [0-9]+$/) {
  split(substr($0, RSTART + 2), part, "]: ")
  run_hist[substr($0, 10, RSTART - 10), part[1]] = part[2]
  next
}

/^@waits_of\[/ && match($0, /, [0-9]+\]: [0-9]+$/) {
  split(substr($0, RSTART + 2), part, "]: ")
  wait_hist[substr($0, 11, RSTART - 11), part[1]] = part[2]
  next
}

/^@name_of\[[0-9]+\]: / { name_of[substr($1, 10, length($1) - 11)] = substr($0, length($1) + 2); next }

# @blocked_in[fiber, <a kernel frame per line>]: ns. The frames up to
# schedule are how every thread leaves the CPU.
/^@blocked_in\[[0-9]+,/ {
  stack_of = substr($1, 13, length($1) - 13)
  stack = ""; leaving = 1
  if (match($0, /\]: [0-9]+$/)) { pending[stack_of, stack] += substr($0, RSTART + 3); stack_of = "" }
  next
}

stack_of != "" && /^\]: [0-9]+$/ { pending[stack_of, stack] += $2; stack_of = ""; next }

stack_of != "" {
  frame = $1
  sub(/\+.*/, "", frame)
  if (leaving && frame ~ /^(perf_trace_sched_switch|trace_event_raw_event_sched_switch|__traceiter_sched_switch|__bpf_trace_sched_switch|bpf_trace_run[0-9]*|__schedule|schedule)$/) next
  leaving = 0
  stack = stack (stack == "" ? "" : " < ") frame
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

{ message($0) }
