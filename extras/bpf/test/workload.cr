# Workload for validating the bpftrace tools against known behaviour:
#
# - "busy-loop" blocks its thread for BUSY_MS (default 2000) every 5 s
#   without yielding: stalls.bt must report it by name, oncpu.bt must rank it
# - "allocator" churns the heap so collections happen
# - "spawner" spawns 100 "short-lived" fibers every 100 ms: fibers.bt
#   must show ~1000/s spawned and finished
#
# Ground truth for gc.bt: every collection is recorded in-process through
# GC_set_on_collection_event (no allocation in the callback) and printed as
#   hook <end_ns> collection_us=<n> stw_us=<n>
# with end_ns on CLOCK_MONOTONIC, the clock bpftrace's nsecs uses.
#
#   crystal build --release extras/bpf/test/workload.cr -o bin/bpf-workload
#   bin/bpf-workload & extras/bpf/lavinmq-bpf stalls $!

module GCHook
  MAX = 1 << 16
  @@buf = Pointer(UInt64).malloc(MAX * 3)
  @@count = 0
  @@start = 0_u64
  @@stw_start = 0_u64
  @@stw = 0_u64

  def self.install
    LibGC.set_on_collection_event(->(event : LibGC::EventType) {
      now = Crystal::System::Time.ticks
      case event
      when .start?            then @@start = now
      when .pre_stop_world?   then @@stw_start = now
      when .post_start_world? then @@stw += now - @@stw_start
      when .end?
        if @@count < MAX
          @@buf[@@count * 3] = now
          @@buf[@@count * 3 + 1] = now - @@start
          @@buf[@@count * 3 + 2] = @@stw
          @@count += 1
        end
        @@stw = 0_u64
      end
      nil
    })
    spawn(name: "gc-hook-log") do
      printed = 0
      loop do
        sleep 1.second
        while printed < @@count
          i = printed * 3
          STDOUT.puts "hook #{@@buf[i]} collection_us=#{@@buf[i + 1] // 1000} stw_us=#{@@buf[i + 2] // 1000}"
          printed += 1
        end
        STDOUT.flush
      end
    end
  end
end

GCHook.install

busy_ms = (ENV["BUSY_MS"]? || "2000").to_i
spawn(name: "busy-loop") do
  loop do
    sleep 5.seconds
    deadline = Time.monotonic + busy_ms.milliseconds
    x = 0_u64
    while Time.monotonic < deadline
      x &+= 1
    end
    STDOUT.puts "busy-loop blocked #{busy_ms} ms at #{Crystal::System::Time.ticks}"
  end
end

spawn(name: "allocator") do
  keep = Array(Array(Int32)).new
  loop do
    1000.times { keep << Array(Int32).new(256, 0) }
    keep.clear if keep.size > 200_000
    sleep 1.millisecond
  end
end

spawn(name: "spawner") do
  loop do
    100.times { spawn(name: "short-lived") { sleep 1.millisecond } }
    sleep 100.milliseconds
  end
end

sleep
