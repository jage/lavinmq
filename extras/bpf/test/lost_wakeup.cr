# Ground truth for wakeups.bt: 50 UNIX socket pairs ping-pong one byte on an
# 8-thread parallel context, with a 2 s read timeout (TIMEOUT_MS). A round
# trip takes microseconds, so every read that times out lost its wakeup (the
# polling event loop race fixed in crystal-lang/crystal, polling-io-timeout-
# race); it prints how many per second. On a Crystal with the fix it prints 0.
#
#   crystal build --release --frame-pointers always extras/bpf/test/lost_wakeup.cr -o bin/bpf-lost-wakeup
#   bin/bpf-lost-wakeup & extras/bpf/lavinmq-bpf wakeups $! 1000
require "socket"

ctx = Fiber::ExecutionContext::Parallel.new("ping-pong", 8)
timeouts = Atomic(Int32).new(0)
timeout = (ENV["TIMEOUT_MS"]? || "2000").to_i.milliseconds

50.times do
  left, right = UNIXSocket.pair
  right.read_timeout = timeout

  ctx.spawn(name: "echo") do
    buf = Bytes.new(1)
    while left.read(buf) == 1
      left.write(buf)
    end
  rescue IO::Error
  end

  ctx.spawn(name: "pinger") do
    buf = Bytes.new(1)
    loop do
      right.write(buf)
      begin
        right.read(buf)
      rescue IO::TimeoutError
        timeouts.add(1)
      end
      sleep 100.microseconds
    end
  end
end

loop do
  sleep 1.second
  STDOUT.puts "#{Time.utc.to_s("%T")} timed out reads: #{timeouts.swap(0)}"
  STDOUT.flush
end
