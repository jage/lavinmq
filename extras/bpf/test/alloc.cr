# Ground truth for record's allocation samples: "small" allocates 40 MB/s
# of 64-byte objects in make_small, "large" 80 MB/s of 64 KB buffers in
# make_large (less, by the time the work takes between sleeps), and each
# counts what it requested. Every second it prints the counts with a
# CLOCK_MONOTONIC time, bpftrace's clock:
#   count <ns> <small bytes> <large bytes>
#
#   crystal build --release --frame-pointers always extras/bpf/test/alloc.cr -o bin/bpf-alloc
#   bin/bpf-alloc & extras/bpf/lavinmq-bpf record $! 10
class Small
  @a = 0_i64
  @b = 0_i64
  @c = 0_i64
  @d = 0_i64
  @e = 0_i64
  @f = 0_i64
  @g = 0_i64
end

@[NoInline]
def make_small(n)
  keep = nil
  n.times { keep = Small.new }
  keep
end

@[NoInline]
def make_large(n)
  keep = nil
  n.times { keep = Bytes.new(65536) }
  keep
end

SMALL = Atomic(Int64).new(0)
LARGE = Atomic(Int64).new(0)
STDOUT.sync = true
puts "pid #{Process.pid}, Small is #{instance_sizeof(Small)} bytes"
spawn(name: "small") do
  loop do
    n = 40 * 1024 * 1024 // 64 // 100 # per 10 ms
    make_small(n)
    SMALL.add(n.to_i64 * 64)
    sleep 10.milliseconds
  end
end
spawn(name: "large") do
  loop do
    n = 80 * 1024 * 1024 // 65536 // 100
    make_large(n)
    LARGE.add(n.to_i64 * 65536)
    sleep 10.milliseconds
  end
end
# cumulative bytes on CLOCK_MONOTONIC, bpftrace's nsecs
loop do
  sleep 1.second
  LibC.clock_gettime(LibC::CLOCK_MONOTONIC, out ts)
  puts "count #{ts.tv_sec.to_i64 * 1_000_000_000 + ts.tv_nsec} #{SMALL.get} #{LARGE.get}"
end
