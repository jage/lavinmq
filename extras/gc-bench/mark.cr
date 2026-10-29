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
GC.collect
times = (1..10).map { Time.measure { GC.collect }.total_milliseconds }.sort
st = GC.prof_stats
printf("threads %d fibers %5d nodes %8d markers %2d  heap %4d MB  collect p50 %6.1f ms  min %6.1f ms\n", threads, fibers, nodes, st.markers_m1 + 1, st.heap_size >> 20, times[5], times[0])
