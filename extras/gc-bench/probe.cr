lib LibGCVer
  fun get_version = GC_get_version : UInt32
end

# Small-heap probe: RSS after GC init, ~20 MB of small linked objects, 100 parked fibers,
# 50 collections. Prints VmRSS (kB) at each step and the mean collect time.
class Node
  def initialize(@next : Node?, @v : Int64)
  end
end

def rss_kb
  File.read("/proc/self/status")[/VmRSS:\s+(\d+)/, 1].to_i
end

module Keep
  class_property head : Node? = nil
end

rss_init = rss_kb
625_000.times { |i| Keep.head = Node.new(Keep.head, i.to_i64) } # 625k x 32 B = 20 MB
ch = Channel(Nil).new
100.times { spawn { ch.receive } }
sleep 0.1.seconds
rss_alloc = rss_kb
t = Time.measure { 50.times { GC.collect } }
rss_end = rss_kb
st = GC.prof_stats
printf("rss_init %d rss_alloc %d rss_end %d kB  heap %d MB  collect mean %.3f ms  version %s\n",
  rss_init, rss_alloc, rss_end, st.heap_size >> 20, t.total_milliseconds / 50,
  LibGCVer.get_version.to_s(16))
