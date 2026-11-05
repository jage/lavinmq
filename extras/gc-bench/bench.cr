require "stdlib/libc"
require "lavinmq/config"
require "lavinmq/stats"

class LavinMQ::FakeQueue
  include LavinMQ::Stats
  rate_stats(
    {"ack", "deliver", "deliver_no_ack", "deliver_get", "confirm", "get", "get_no_ack", "publish", "redeliver", "reject", "return_unroutable", "dedup"},
    {"message_count", "unacked_count"})
  property message_count = 0_u32
  property unacked_count = 0_u32

  def work(n)
    @publish_count.add(n.to_u64)
    @deliver_count.add(n.to_u64)
    @ack_count.add(n.to_u64)
    @message_count = (@message_count &+ n) % 1000
  end

end

def tick(queues)
  queues.each &.update_rates
  {% if LavinMQ.has_constant?(:StatBlockPool) %}
    LavinMQ::StatBlockPool.trim
  {% end %}
end

def rss_mb
  File.read("/proc/self/statm").split[1].to_i64 * 4096 // 1024 // 1024
end

def report(label, queues, ticks, &)
  t = Time.measure do
    ticks.times do |i|
      yield i
      tick(queues)
    end
  end
  GC.collect
  s = GC.stats
  printf("%-28s tick %6.1f ms  heap %6d MB  free %6d MB  rss %6d MB\n", label,
    t.total_milliseconds / ticks, s.heap_size // 1024 // 1024, s.free_bytes // 1024 // 1024, rss_mb)
end

n = (ARGV[0]? || "100000").to_i
queues = Array(LavinMQ::FakeQueue).new(n) { LavinMQ::FakeQueue.new }
report("idle x130", queues, 130) { }
report("10% busy x130", queues, 130) { |i| queues.each_with_index { |q, j| q.work(i + 1) if j % 10 == 0 } }
report("idle again x130", queues, 130) { }
report("all busy x130", queues, 130) { |i| queues.each { |q| q.work(i + 1) } }
report("idle again x130", queues, 130) { }
8.times do |i|
  GC.collect
  s = GC.stats
  printf("after GC.collect #%d          heap %6d MB  free %6d MB  unmapped %6d MB  rss %6d MB\n", i + 1, s.heap_size // 1024 // 1024, s.free_bytes // 1024 // 1024, s.unmapped_bytes // 1024 // 1024, rss_mb)
end
