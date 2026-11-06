class Node
  def initialize(@next : Node?, @a : Array(Int32)?, @s : String)
  end
end

# LEAVES=1: each node also points to two pointer-free heap objects (a String and a 64-byte
# buffer), like LavinMQ's names and IO buffers. Marking sets their mark bits but never scans
# them, which is what prefetch on push (843bb7e6) stops prefetching.
class LeafNode
  def initialize(@next : LeafNode?, @s : String, @b : Bytes)
  end
end

module Keep
  class_property head : Node? = nil
  class_property heads = [] of Node?
  class_property leaves = [] of LeafNode?
end

fibers = (ARGV[0]? || "0").to_i
nodes = (ARGV[1]? || "1000000").to_i
threads = (ARGV[2]? || "0").to_i
if ENV["LEAVES"]?
  Keep.leaves = Array(LeafNode?).new(1000, nil)
  nodes.times { |i| Keep.leaves[i % 1000] = LeafNode.new(Keep.leaves[i % 1000], i.to_s, Bytes.new(64)) }
elsif ENV["TREE"]?
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
# COLLECTS=<n> runs more collections, e.g. to keep the process alive for a profile
times = (1..(ENV["COLLECTS"]? || "10").to_i).map { Time.measure { GC.collect }.total_milliseconds }.sort
st = GC.prof_stats
printf("threads %d fibers %5d nodes %8d markers %2d  heap %4d MB  collect p50 %6.1f ms  min %6.1f ms\n", threads, fibers, nodes, st.markers_m1 + 1, st.heap_size >> 20, times[times.size // 2], times[0])
