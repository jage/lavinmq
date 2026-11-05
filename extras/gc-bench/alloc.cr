# Allocation throughput: <threads> threads in a parallel execution context, each allocating
# <millions> M small objects (a 32-byte pointerful object and a ~24-byte String per step) and
# keeping the latest <keep> of them, so the heap stays small and collections are frequent.
# Exercises the thread-local allocation fast path, free-list refills under the allocator lock
# and the collector's write-hot shared data, not marking.
#   alloc <threads> <millions> [keep]
class Obj
  def initialize(@a : Obj?, @s : String, @i : Int64)
  end
end

threads = (ARGV[0]? || "1").to_i
steps = ((ARGV[1]? || "20").to_f * 1_000_000).to_i
keep = (ARGV[2]? || "4096").to_i
ctx = Fiber::ExecutionContext::Parallel.new("alloc", threads)
done = Channel(Nil).new
GC.collect
gc0 = GC.prof_stats
t = Time.measure do
  threads.times do |w|
    ctx.spawn do
      ring = Array(Obj?).new(keep, nil)
      prev = nil
      steps.times do |i|
        o = Obj.new(prev, (i &+ w).to_s, i.to_i64)
        prev = i % 64 == 0 ? nil : o
        ring[i % keep] = o
      end
      done.send(nil)
    end
  end
  threads.times { done.receive }
end
gc1 = GC.prof_stats
total = threads.to_i64 * steps
printf("threads %d steps %dM keep %d  wall %7.1f ms  %6.2f ns/step/thread  gcs %4d  heap %4d MB\n",
  threads, steps // 1_000_000, keep, t.total_milliseconds, t.total_nanoseconds / steps,
  gc1.gc_no - gc0.gc_no, gc1.heap_size >> 20)
