# Workload for top's BLOCK%: fibers that block their thread in a syscall.
#
# - "blocker" every second blocks its thread for 300 ms in usleep and then
#   spins for 100 ms: top must show it 40% busy, 30% blocked
# - "long-blocker" every 6 s blocks its thread for 2.5 s: top must show its
#   thread 100% busy and blocked while that lasts
#
#   crystal build --release extras/bpf/test/block.cr -o bin/bpf-block
#   bin/bpf-block & extras/bpf/lavinmq-bpf top $!

lib LibC
  fun usleep(usec : UInt32) : Int32
end

spawn(name: "blocker") do
  loop do
    sleep 600.milliseconds
    LibC.usleep(300_000)
    deadline = Time.instant + 100.milliseconds
    x = 0_u64
    while Time.instant < deadline
      x &+= 1
    end
  end
end
spawn(name: "long-blocker") do
  loop do
    sleep 6.seconds
    LibC.usleep(2_500_000)
  end
end
sleep
