require "stdlib/libc"
require "lavinmq/config"
require "lavinmq/stats"

module LavinMQ
  class FQueue
    include Stats
    rate_stats(
      {"ack", "deliver", "deliver_no_ack", "deliver_get", "confirm", "get", "get_no_ack", "publish", "redeliver", "reject", "return_unroutable", "dedup"},
      {"message_count", "unacked_count"})
    property message_count = 0_u32
    property unacked_count = 0_u32

    def work(n : Int32)
      @publish_count.add(n.to_u64)
      @deliver_count.add(n.to_u64)
      @ack_count.add(n.to_u64)
      @message_count = (@message_count &+ n.to_u32) % 1000
    end
  end

  class FChannel
    include Stats
    rate_stats({"ack", "get", "get_no_ack", "publish", "deliver", "deliver_no_ack", "deliver_get", "redeliver", "reject", "confirm", "return_unroutable"})

    def work(n : Int32)
      @publish_count.add(n.to_u64)
      @confirm_count.add(n.to_u64)
    end
  end

  class FConn
    include Stats
    rate_stats({"send_oct", "recv_oct"})
    getter channel = FChannel.new
    getter name : String

    def initialize(i : Int32)
      @name = "127.0.0.1:#{i} -> 127.0.0.1:5672"
      @recv_oct_count.add(600_u64) # handshake in the first interval
      @send_oct_count.add(500_u64)
    end

    def work(n : Int32)
      @recv_oct_count.add(n.to_u64 * 100)
      @send_oct_count.add(n.to_u64 * 20)
      @channel.work(n)
    end

    def close
      {% if LavinMQ.has_constant?(:StatBlockPool) %}
        LavinMQ::Stats.retire(self)
        LavinMQ::Stats.retire(@channel)
      {% end %}
    end
  end
end

class Node
  def initialize(@next : Node?, @payload : Bytes)
  end
end

# GC pause timing, written from inside the collector without allocating
MAX_EVENTS = 1_000_000
PAUSES     = Pointer(UInt64).new(LibC.malloc(MAX_EVENTS * 8).address)
module GCTimes
  @@start = 0_u64
  @@count = 0

  def self.count
    @@count
  end

  def self.install
    LibGC.set_on_collection_event(->(event : LibGC::EventType) {
      case event
      when .start?
        @@start = Crystal::System::Time.ticks
      when .end?
        if @@count < MAX_EVENTS
          PAUSES[@@count] = Crystal::System::Time.ticks - @@start
          @@count += 1
        end
      end
      nil
    })
  end
end

GCTimes.install

def pct(a : Array(Float64), p : Float64) : Float64
  return 0.0 if a.empty?
  s = a.sort
  s[Math.min(s.size - 1, (s.size * p).to_i)]
end

def status(key) : Int64
  File.read("/proc/self/status").each_line do |l|
    return l.split[1].to_i64 // 1024 if l.starts_with?(key)
  end
  0_i64
end

scenario = ARGV[0]? || "steady"
TICKS   = 240
NQ      = 20_000
NC      = 20_000
rng = Random.new(7)

ballast = nil.as(Node?)
1_000_000.times { ballast = Node.new(ballast, Bytes.new(48)) }

queues = Array(LavinMQ::FQueue).new(NQ) { LavinMQ::FQueue.new }
conn_id = 0
conns = Array(LavinMQ::FConn).new(NC) { conn_id += 1; LavinMQ::FConn.new(conn_id) }
phase = Array(Int32).new(NQ) { rng.rand(150) }
GC.collect
gc_before = GCTimes.count

ticks = [] of Float64
heap_peak = 0_u64
stats_alloc = 0_u64
gcs_at = [] of Int32
wall = Time.measure do
  TICKS.times do |t|
    # Mutator garbage, as frames, HTTP requests and the like would make
    junk = nil.as(Node?)
    100_000.times { junk = Node.new(junk, Bytes.new(96)) }
    junk = nil

    case scenario
    when "churn", "churn5k"
      (scenario == "churn" ? 500 : 5000).times do
        i = rng.rand(NC)
        conns[i].close
        conn_id += 1
        conns[i] = LavinMQ::FConn.new(conn_id)
      end
    when "flood"
      if t == 20 || t == 140
        conns.each &.close
        NC.times { |i| conn_id += 1; conns[i] = LavinMQ::FConn.new(conn_id) }
      end
    end

    if scenario == "flap"
      queues.each_with_index { |q, i| q.work(t + 1) if (t + phase[i]) % 150 < 5 }
    else
      queues.each_with_index { |q, i| q.work(t + 1) if i % 20 == 0 }
    end
    conns.each_with_index { |c, i| c.work(t % 7 + 1) if i % 10 == 0 }

    alloc_before = GC.stats.total_bytes
    ticks << Time.measure do
      queues.each &.update_rates
      conns.each { |c| c.update_rates; c.channel.update_rates }
      {% if LavinMQ.has_constant?(:StatBlockPool) %}
        LavinMQ::Stats.release_retired
        LavinMQ::StatBlockPool.trim
      {% end %}
    end.total_milliseconds
    stats_alloc += GC.stats.total_bytes - alloc_before
    heap_peak = Math.max(heap_peak, GC.stats.heap_size)
    gcs_at << GCTimes.count
  end
end

pauses = (gc_before...GCTimes.count).map { |i| PAUSES[i] / 1_000_000.0 }
printf("%-6s gcs %4d  pause p50 %6.1f p99 %6.1f max %6.1f total %7.0f ms | tick p50 %5.1f p99 %5.1f max %6.1f ms | heap peak %5d MB  rss peak %5d end %5d MB | wall %5.1f s | stats alloc %5d MB\n",
  scenario, pauses.size, pct(pauses, 0.5), pct(pauses, 0.99), pauses.max? || 0.0, pauses.sum,
  pct(ticks, 0.5), pct(ticks, 0.99), ticks.max,
  heap_peak // 1024 // 1024, status("VmHWM:"), status("VmRSS:"), wall.total_seconds, stats_alloc // 1024 // 1024)
ballast.hash
if ENV["TIMELINE"]?
  prev = gc_before
  line = String.build do |io|
    gcs_at.each_slice(20) { |sl| io << (sl.last - prev) << ' '; prev = sl.last }
  end
  puts "  gcs per 20 ticks: #{line}"
  st = GC.stats
  puts "  heap #{st.heap_size >> 20} MB free #{st.free_bytes >> 20} MB"
end
