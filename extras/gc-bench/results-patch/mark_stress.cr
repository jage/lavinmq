class Node
  def initialize(@next : Node?, @a : Array(Int32)?, @s : String)
  end
end

module Keep
  class_property head : Node? = nil
  class_property heads = [] of Node?
end

fibers = (ARGV[0]? || "0").to_i
nodes = (ARGV[1]? || "1000000").to_i
threads = (ARGV[2]? || "0").to_i
if ENV["TREE"]?
  Keep.heads = Array(Node?).new(1000, nil)
  nodes.times { |i| Keep.heads[i % 1000] = Node.new(Keep.heads[i % 1000], i % 4 == 0 ? [i] : nil, "x") }
else
  nodes.times { |i| Keep.head = Node.new(Keep.head, i % 4 == 0 ? [i] : nil, "x") }
end
ch = Channel(Nil).new
ctx = threads > 0 ? Fiber::ExecutionContext::Parallel.new("workers", threads) : nil
fibers.times { ctx ? ctx.spawn { ch.receive } : spawn { ch.receive } }
sleep 0.2.seconds
# Stress copy of mark.cr: COLLECTS (default 250) collections, some garbage allocated between them,
# p50 per block of 50, then the live structure is walked and checked so a marking bug that frees
# reachable objects shows up as a wrong count or a crash.
collects = (ENV["COLLECTS"]? || "250").to_i
times = [] of Float64
garbage = nil
collects.times do |i|
  1000.times { |j| garbage = Node.new(garbage, nil, "g") }
  garbage = nil
  times << Time.measure { GC.collect }.total_milliseconds
  if (i + 1) % 50 == 0
    blk = times[-50..].sort
    printf("collections %4d  block p50 %6.1f ms  max %6.1f ms\n", i + 1, blk[25], blk[-1])
  end
end
count = 0
sum = 0_i64
check = ->(h : Node?) {
  n = h
  while n
    count += 1
    if a = n.@a
      sum += a[0]
    end
    raise "bad string" unless n.@s == "x"
    n = n.@next
  end
}
if ENV["TREE"]?
  Keep.heads.each { |h| check.call(h) }
else
  check.call(Keep.head)
end
expected = (0...nodes).select { |i| i % 4 == 0 }.sum(0_i64)
st = GC.prof_stats
printf("verify nodes %d/%d sum %s  heap %d MB  %s\n", count, nodes, sum == expected ? "ok" : "BAD", st.heap_size >> 20, count == nodes && sum == expected ? "PASS" : "FAIL")
