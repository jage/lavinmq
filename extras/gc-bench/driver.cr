require "amqp-client"

# Drives a broker with flapping queues plus connection churn or reconnect floods.
#   driver <churn|flood> <seconds>
# NQ (queues, default 20000) and NCONN (churn pool size, default 2000) scale it down.
mode = ARGV[0]
seconds = ARGV[1].to_i
uri = "amqp://guest:guest@127.0.0.1"
NQ   = (ENV["NQ"]? || 20_000).to_i
TICK = 500.milliseconds # the broker's stats_interval
STDOUT.sync = true

client = AMQP::Client.new(uri)
setup = client.connect
sch = setup.channel
NQ.times { |i| sch.queue_declare("flap-#{i}", durable: false, auto_delete: false, no_wait: true) }
sch.queue_declare("flap-#{NQ - 1}", passive: true) # declarations done
puts "declared #{NQ} queues"

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

def open(client) : {AMQP::Client::Connection, AMQP::Client::Channel}
  c = client.connect
  ch = c.channel
  3.times { ch.basic_publish("hello", "amq.topic", "x") } # handshake-time traffic
  {c, ch}
end

pool_size = mode == "flood" ? 5000 : (ENV["NCONN"]? || 2000).to_i
pool = Array({AMQP::Client::Connection, AMQP::Client::Channel}).new(pool_size) { open(client) }
puts "opened #{pool_size} connections"
puts "measure_start #{Crystal::System::Time.ticks}"
started = Time.instant
t = 0
reconnects = 0
while Time.instant - started < seconds.seconds
  start = Time.instant
  case mode
  when "churn" # 200 reconnects/s
    100.times do
      i = rand(pool_size)
      pool[i][0].close rescue nil
      pool[i] = open(client)
      reconnects += 1
    end
  when "flood" # everyone reconnects at once, twice
    if t == 60 || t == 300
      pool.each { |c, _| c.close rescue nil }
      pool_size.times { |i| pool[i] = open(client) }
      reconnects += pool_size
      puts "flood at tick #{t} took #{(Time.instant - start).total_seconds.round(1)}s"
    end
  end
  # A fifth of the connections publish now and then
  pool.each_with_index { |(_, ch), i| ch.basic_publish("y", "amq.topic", "x") if i % 5 == 0 && (t + i) % 3 == 0 }
  t += 1
  left = TICK - (Time.instant - start)
  sleep left if left.positive?
end
done = true
puts "measure_end #{Crystal::System::Time.ticks}"
puts "reconnects #{reconnects}"
