require "amqp-client"
require "wait_group"

# Drives a broker with flapping queues plus connection churn, reconnect floods or a reconnect storm.
#   driver <churn|flood|storm|declare> <seconds>
# NQ (queues, default 20000) and NCONN (churn pool size, default 2000) scale it down.
# CHURN_RATE: reconnects/s in churn and storm mode (default 200).
# storm: opens the NCONN pool as fast as possible, CONC (default 500) handshakes in flight, a
#   handshake that takes over HS_TIMEOUT seconds (default 10) is given up and retried, then churns
#   for <seconds>. declare: only declares the queues. DECLARE=0 skips declaring.
# CONSUMERS: the first that many pool connections consume from a queue each (default 0).
# POOL_PUB=0 stops a fifth of the pool from publishing now and then. AMQP_URI sets the broker URI.
mode = ARGV[0]
seconds = ARGV[1].to_i
uri = ENV["AMQP_URI"]? || "amqp://guest:guest@127.0.0.1"
NQ         = (ENV["NQ"]? || 20_000).to_i
TICK       = 500.milliseconds # the broker's stats_interval
CHURN_RATE = (ENV["CHURN_RATE"]? || 200).to_f
CONSUMERS  = (ENV["CONSUMERS"]? || 0).to_i
HS_TIMEOUT = (ENV["HS_TIMEOUT"]? || 10).to_f.seconds
STDOUT.sync = true

client = AMQP::Client.new(uri)
setup = client.connect
sch = setup.channel
unless ENV["DECLARE"]? == "0"
  NQ.times { |i| sch.queue_declare("flap-#{i}", durable: false, auto_delete: false, no_wait: true) }
  sch.queue_declare("flap-#{NQ - 1}", passive: true) # declarations done
  puts "declared #{NQ} queues"
end
exit if mode == "declare"

done = false
spawn(name: "flap") do
  next if ENV["FLAP"]? == "0"
  # Each queue is busy for 5 ticks every 150, so history buffers are taken and dropped over and over
  ch = setup.channel
  t = 0
  until done
    start = Time.instant
    NQ.times do |i|
      next unless (t + i) % 150 < 5
      ch.basic_publish("x", "", "flap-#{i}")
      ch.basic_get("flap-#{i}", no_ack: true)
    end
    t += 1
    left = TICK - (Time.instant - start)
    sleep left if left.positive?
  end
end

alias Conn = {AMQP::Client::Connection, AMQP::Client::Channel}

def open(client, i) : Conn
  c = client.connect
  ch = c.channel
  3.times { ch.basic_publish("hello", "amq.topic", "x") } # handshake-time traffic
  ch.basic_consume("flap-#{i % NQ}", no_ack: true) { } if i < CONSUMERS
  {c, ch}
end

class Attempts
  property timeouts = 0
  property errors = Hash(String, Int32).new(0)
  property latencies = [] of Float64
end

# Opens a connection like a client with a handshake timeout: a slow attempt is abandoned (closed
# once it completes) and retried
def open_retrying(client, i, stats : Attempts) : Conn
  loop do
    result = Channel(Conn | Exception).new(1)
    abandoned = false
    start = Time.instant
    spawn do
      r = begin
        open(client, i)
      rescue ex
        ex
      end
      if abandoned
        r[0].close rescue nil if r.is_a?(Conn)
      else
        result.send(r)
      end
    end
    select
    when r = result.receive
      if r.is_a?(Conn)
        stats.latencies << (Time.instant - start).total_seconds
        return r
      end
      stats.errors[r.class.name] += 1
      sleep 1.second
    when timeout(HS_TIMEOUT)
      abandoned = true
      stats.timeouts += 1
    end
  end
end

pool_size = mode == "flood" ? 5000 : (ENV["NCONN"]? || 2000).to_i
slots = Array(Conn?).new(pool_size, nil)
stats = Attempts.new
if mode == "storm"
  conc = (ENV["CONC"]? || 500).to_i
  puts "storm_start #{Crystal::System::Time.ticks}"
  start = Time.instant
  nxt = 0
  wg = WaitGroup.new(conc)
  conc.times do
    spawn do
      while (i = nxt) < pool_size
        nxt += 1
        slots[i] = open_retrying(client, i, stats)
      end
    ensure
      wg.done
    end
  end
  wg.wait
  l = stats.latencies.sort!
  puts "storm_end #{Crystal::System::Time.ticks} took #{(Time.instant - start).total_seconds.round(2)}s " \
       "handshake p50 #{l[l.size // 2].round(3)}s p99 #{l[l.size * 99 // 100].round(3)}s max #{l.last.round(3)}s " \
       "timeouts #{stats.timeouts} errors #{stats.errors}"
else
  pool_size.times { |i| slots[i] = open(client, i) }
end
pool = slots.map(&.not_nil!)
puts "opened #{pool_size} connections"
puts "measure_start #{Crystal::System::Time.ticks}"
started = Time.instant
t = 0
reconnects = 0
owed = 0.0
while Time.instant - started < seconds.seconds
  start = Time.instant
  case mode
  when "churn", "storm"
    owed += CHURN_RATE * TICK.total_seconds
    while owed >= 1
      owed -= 1
      i = rand(pool_size)
      pool[i][0].close rescue nil
      pool[i] = mode == "storm" ? open_retrying(client, i, stats) : open(client, i)
      reconnects += 1
    end
  when "flood" # everyone reconnects at once, twice
    if t == 60 || t == 300
      pool.each { |c, _| c.close rescue nil }
      pool_size.times { |i| pool[i] = open(client, i) }
      reconnects += pool_size
      puts "flood at tick #{t} took #{(Time.instant - start).total_seconds.round(1)}s"
    end
  end
  unless ENV["POOL_PUB"]? == "0"
    # A fifth of the connections publish now and then
    pool.each_with_index { |(_, ch), i| ch.basic_publish("y", "amq.topic", "x") if i % 5 == 0 && (t + i) % 3 == 0 }
  end
  t += 1
  left = TICK - (Time.instant - start)
  sleep left if left.positive?
end
done = true
puts "measure_end #{Crystal::System::Time.ticks}"
puts "reconnects #{reconnects} timeouts #{stats.timeouts} errors #{stats.errors}"
