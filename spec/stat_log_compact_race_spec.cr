require "./spec_helper"

# Memory-safety stress for the compact path: a writer repeatedly materializes
# then compacts an object's stats buffers (compact drops each column buffer
# for the GC) while reader fibers iterate StatLogViews to JSON like the HTTP
# read path. A view that did not pin its column's buffer via the base pointer
# would dereference a freed buffer.
module LavinMQ
  private class RaceProbe
    include Stats
    rate_stats({"a", "b", "c"}, {"d"})

    @d = 0_u32

    def d
      @d
    end

    def bump(n : UInt64)
      @a_count.add(n)
      @b_count.add(n)
      @c_count.add(n)
      @d &+= 1
    end

    def constant?
      stats_constant_folded?
    end
  end

  describe "StatLogView compact/read race" do
    it "never frees a buffer out from under a concurrent reader" do
      cap = Config.instance.stats_log_size
      probe = RaceProbe.new
      stop = Atomic(Int32).new(0)
      errors = Atomic(Int32).new(0)
      done = Channel(Nil).new
      readers = 8

      readers.times do
        spawn do
          until stop.get(:relaxed) == 1
            begin
              io = IO::Memory.new
              jb = JSON::Builder.new(io)
              jb.document do
                jb.array do
                  probe.a_log.to_json(jb) # column 0 (base)
                  probe.b_log.to_json(jb) # column 1
                  probe.c_log.to_json(jb) # column 2
                  probe.d_log.to_json(jb) # count column
                end
              end
              probe.b_log.to_a
              probe.c_log.each { |v| v }
            rescue
              errors.add(1)
            end
            Fiber.yield
          end
          done.send(nil)
        end
      end

      materializes = 0
      compacts = 0
      300.times do |c|
        probe.bump(c.odd? ? 7_u64 : 131_u64) # changing delta -> rate diverges -> materialize
        probe.update_rates
        materializes += 1 unless probe.constant?
        (cap + 1).times { probe.update_rates } # constant (no bump) -> rate holds -> compact
        compacts += 1 if probe.constant?
        GC.collect # with GC_UNMAP_THRESHOLD=1 may unmap a just-freed buffer
        Fiber.yield
      end

      stop.set(1, :relaxed)
      readers.times { done.receive }

      errors.get(:relaxed).should eq 0
      (materializes > 100).should be_true # really exercised buffered logs
      (compacts > 100).should be_true     # ...and really compacted them
    end
  end
end
