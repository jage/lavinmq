require "./typetable"
# Records every collection's duration without allocating in the collector, and appends them
# to $GC_PAUSE_FILE once a second as "end_ns duration_ns" lines.
lib LibC
  fun backtrace(buffer : Void**, size : Int) : Int
end

module GCPauses
  MAX     = 1 << 20
  @@buf = Pointer(UInt64).new(LibC.malloc(MAX * 16).address)
  @@start = 0_u64
  @@count = 0
  @@written = 0
  @@phase_start = 0_u64
  @@stop_ns = 0_u64
  @@mark_ns = 0_u64
  @@phases = Pointer(UInt64).new(LibC.malloc(MAX * 16).address)
  MAX_TRACES = 4096
  DEPTH      = 40
  @@stacks = Pointer(Void*).new(LibC.malloc(MAX_TRACES * DEPTH * 8).address)
  @@depth = Pointer(Int32).new(LibC.malloc(MAX_TRACES * 4).address)
  @@traces = 0
  @@traces_written = 0

  def self.dump_traces(io)
    while @@traces_written < @@traces
      i = @@traces_written
      io << "trace"
      @@depth[i].times { |d| io << ' ' << @@stacks[i * DEPTH + d].address.to_s(16) }
      io << '\n'
      @@traces_written += 1
    end
    io.flush
  end

  def self.install(path : String)
    LibGC.set_on_collection_event(->(event : LibGC::EventType) {
      case event
      when .start?
        @@start = Crystal::System::Time.ticks
        if @@traces < MAX_TRACES # where the collection was triggered from
          n = LibC.backtrace(@@stacks + @@traces * DEPTH, DEPTH)
          @@depth[@@traces] = n
          @@traces += 1
        end
      when .pre_stop_world?
        @@phase_start = Crystal::System::Time.ticks
      when .post_stop_world?
        @@stop_ns = Crystal::System::Time.ticks - @@phase_start
      when .mark_start?
        @@phase_start = Crystal::System::Time.ticks
      when .mark_end?
        @@mark_ns = Crystal::System::Time.ticks - @@phase_start
      when .end?
        if @@count < MAX
          @@phases[@@count * 2] = @@stop_ns
          @@phases[@@count * 2 + 1] = @@mark_ns
          now = Crystal::System::Time.ticks
          @@buf[@@count * 2] = now
          @@buf[@@count * 2 + 1] = now - @@start
          @@count += 1
        end
      end
      nil
    })
    file = File.open(path, "a")
    traces = File.open("#{path}.traces", "a")
    File.write("#{path}.maps", File.read("/proc/self/maps"))
    File.write("#{path}.version", "#{LibGC.get_version.to_s(16)}\n")
    spawn(name: "gc pause log") do
      loop do
        sleep 1.second
        count = @@count
        while @@written < count
          file.puts "#{@@buf[@@written * 2]} #{@@buf[@@written * 2 + 1]} #{@@phases[@@written * 2]} #{@@phases[@@written * 2 + 1]}"
          @@written += 1
        end
        file.flush
        GCPauses.dump_traces(traces)
      end
    end
  end
end

if pause_path0 = ENV["GC_PAUSE_FILE"]?
  GCPauses.install(pause_path0)
end

lib LibGC
  alias ReachableObjectProc = (Void*, SizeT, Void*) ->
  fun enumerate_reachable_objects_inner = GC_enumerate_reachable_objects_inner(proc : ReachableObjectProc, client_data : Void*)
  fun call_with_alloc_lock = GC_call_with_alloc_lock(fn : Void* -> Void*, data : Void*) : Void*
  fun get_kind_and_size = GC_get_kind_and_size(p : Void*, psize : SizeT*) : Int
end

# Live heap by type: objects with a known type ID are counted per type, the rest (array, deque
# and hash buffers, which have no header) per kind and size. Kind 0 is pointer-free, the GC
# doesn't scan it; the rest is marked through on every collection.
module GCCensus
  MAX_ID  = 1 << 16
  BUCKETS = 32
  @@count = Pointer(Int64).new(LibC.malloc(MAX_ID * 2 * 8).address)
  @@bytes = Pointer(Int64).new(LibC.malloc(MAX_ID * 2 * 8).address)
  @@known = Pointer(Bool).new(LibC.malloc(MAX_ID).address)
  @@ucount = Pointer(Int64).new(LibC.malloc(BUCKETS * 2 * 8).address)
  @@ubytes = Pointer(Int64).new(LibC.malloc(BUCKETS * 2 * 8).address)

  def self.run(path : String)
    names = TypeTable.names
    @@known.clear(MAX_ID)
    names.each_key { |id| @@known[id] = true if 0 <= id < MAX_ID }
    @@count.clear(MAX_ID * 2); @@bytes.clear(MAX_ID * 2)
    @@ucount.clear(BUCKETS * 2); @@ubytes.clear(BUCKETS * 2)
    GC.collect
    LibGC.call_with_alloc_lock(->(_data : Void*) {
      LibGC.enumerate_reachable_objects_inner(->(obj : Void*, bytes : LibGC::SizeT, _d : Void*) {
        kind = LibGC.get_kind_and_size(obj, nil) == 0 ? 0 : 1
        id = obj.as(Int32*).value
        if 0 < id < MAX_ID && @@known[id]
          @@count[id * 2 + kind] += 1
          @@bytes[id * 2 + kind] += bytes.to_i64
        else
          b = Math.min(BUCKETS - 1, 64 - bytes.to_u64.leading_zeros_count)
          @@ucount[b * 2 + kind] += 1
          @@ubytes[b * 2 + kind] += bytes.to_i64
        end
        nil
      }, Pointer(Void).null)
      Pointer(Void).null
    }, Pointer(Void).null)
    rows = [] of {String, Int64, Int64, Int32}
    names.each do |id, name|
      next unless 0 <= id < MAX_ID
      2.times { |k| rows << {name, @@count[id * 2 + k], @@bytes[id * 2 + k], k} if @@count[id * 2 + k] > 0 }
    end
    BUCKETS.times do |b|
      2.times { |k| rows << {"<no header, #{1_i64 << (b - 1)}-#{(1_i64 << b) - 1} B>", @@ucount[b * 2 + k], @@ubytes[b * 2 + k], k} if @@ucount[b * 2 + k] > 0 }
    end
    rows.sort_by! { |r| -r[2] }
    total = rows.sum(&.[2])
    scanned = rows.select { |r| r[3] == 1 }.sum(&.[2])
    File.open(path, "w") do |f|
      st = GC.stats
      f.puts "reachable #{total >> 20} MB, scanned #{scanned >> 20} MB, pointer-free #{(total - scanned) >> 20} MB; heap #{st.heap_size >> 20} MB"
      rows.first(60).each do |name, count, bytes, kind|
        f.printf("%9.1f MB %5.1f%% %9d  %s  %s\n", bytes / 1048576, bytes * 100.0 / total, count, kind == 0 ? "free" : "scan", name)
      end
      fibers = Hash(String, Int32).new(0)
      Fiber.unsafe_each { |fb| fibers[fb.name.to_s.gsub(/\d+/, "N")] += 1 }
      f.puts "fibers by name (digits as N): #{fibers.values.sum}"
      fibers.to_a.sort_by! { |_, n| -n }.first(25).each { |name, n| f.printf("%9d  %s\n", n, name) }
    end
  end
end

if pause_path1 = ENV["GC_PAUSE_FILE"]?
  spawn(name: "gc census") do
    allocs = File.open("#{pause_path1}.allocs", "a")
    loop do
      sleep 1.second
      allocs.puts "#{Crystal::System::Time.ticks} #{GC.stats.total_bytes}"
      allocs.flush
      request = "#{pause_path1}.census-request"
      if File.exists?(request)
        target = File.read(request).strip
        File.delete(request)
        GCCensus.run(target)
      end
    end
  end
end

lib LibGC
  fun get_version = GC_get_version : UInt32
  fun set_allocd_bytes_per_finalizer = GC_set_allocd_bytes_per_finalizer(value : Word)
end

if v = ENV["GC_BYTES_PER_FINALIZER"]?
  LibGC.set_allocd_bytes_per_finalizer(v.to_u64)
end

# Counts finalizer registrations per type ID, in storage that needs no initializer, as
# finalizers are registered before the program's own initializers run
module FinalizerCount
  @@address = 0_u64 # a literal, so it's set statically rather than through __crystal_once

  def self.bump(id : Int32) : Nil
    if @@address.zero?
      counts = Pointer(Int64).new(LibC.malloc(65536 * 8).address)
      counts.clear(65536)
      @@address = counts.address
    end
    Pointer(Int64).new(@@address)[id] += 1 if 0 <= id < 65536
  end

  def self.snapshot : Array({String, Int64})
    return [] of {String, Int64} if @@address.zero?
    counts = Pointer(Int64).new(@@address)
    TypeTable.names.compact_map { |id, name| {name, counts[id]} if 0 <= id < 65536 && counts[id] > 0 }
  end
end

module GC
  private def self.add_finalizer_impl(object : T) forall T
    FinalizerCount.bump(T.crystal_instance_type_id)
    previous_def
  end
end

if pause_path2 = ENV["GC_PAUSE_FILE"]?
  spawn(name: "finalizer counts") do
    loop do
      sleep 1.second
      File.open("#{pause_path2}.finalizers", "a") do |f|
        f << Crystal::System::Time.ticks
        FinalizerCount.snapshot.each { |name, n| f << ' ' << name.gsub(' ', "") << '=' << n }
        f << '\n'
      end
    end
  end
end

# Stall watchdog: a fiber that sleeps 1 s in a loop, like a lease keepalive fiber, and writes
# "wakeup_ns lateness_ns" for every wakeup to $GC_PAUSE_FILE.watchdog
if pause_path3 = ENV["GC_PAUSE_FILE"]?
  spawn(name: "stall watchdog") do
    File.open("#{pause_path3}.watchdog", "a") do |f|
      loop do
        before = Crystal::System::Time.ticks
        sleep 1.second
        now = Crystal::System::Time.ticks
        f << now << ' ' << (now - before).to_i64 - 1_000_000_000 << '\n'
        f.flush
      end
    end
  end
end
