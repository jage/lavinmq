require "./spec_helper"

# Model-based test: random operations on a real MessageStore, checked after
# every step against a reference model of what a queue should hold. Reopens
# and crashes (the store is abandoned without closing, as a killed process
# leaves it) are among the operations, so recovery is checked too.
#
# SEED, SEEDS and STEPS override the defaults, e.g. to run it for longer.
module MessageStoreModel
  # Messages are ids, which the body carries. Ready messages are the requeued
  # ones first, then the unread ones, both in publish order.
  class Reference
    getter requeued = Array(Int32).new
    getter unread = Deque(Int32).new
    getter unacked = Set(Int32).new
    getter bytesizes = Hash(Int32, UInt64).new

    def size
      requeued.size + unread.size
    end

    def bytesize
      requeued.sum(0u64) { |id| bytesizes[id] } + unread.sum(0u64) { |id| bytesizes[id] }
    end

    def first? : Int32?
      requeued.first? || unread.first?
    end

    def shift? : Int32?
      id = requeued.shift? || unread.shift?
      unacked << id if id
      id
    end

    def requeue(id)
      unacked.delete(id)
      requeued << id
      requeued.sort!
    end

    def ack(id)
      unacked.delete(id)
    end

    # After a restart every message not acked is ready, in publish order.
    def restart
      all = (requeued + unread.to_a + unacked.to_a).sort!
      requeued.clear
      unacked.clear
      @unread = Deque(Int32).new(all)
    end
  end

  class Run
    @store : LavinMQ::MessageStore
    @reference = Reference.new
    @positions = Hash(Int32, LavinMQ::SegmentPosition).new
    @abandoned = Array(LavinMQ::MessageStore).new # crashed stores, kept from being collected
    @trace = Array(String).new
    @next_id = 0

    def initialize(@dir : String, seed : UInt64)
      @rng = Random.new(seed)
      @store = LavinMQ::MessageStore.new(@dir, nil)
    end

    def step
      case @rng.rand(100)
      when 0...35  then push
      when 35...60 then shift
      when 60...65 then first
      when 65...75 then requeue
      when 75...90 then ack
      when 90...94 then purge
      when 94...96 then purge_all
      when 96...98 then restart
      else              crash
      end
      check_counters
    end

    def close
      @store.close
    end

    def trace
      @trace.last(25).join("\n")
    end

    private def push
      id = @next_id
      @next_id += 1
      body = "id:#{id}:" + "x" * @rng.rand(0..(@rng.rand(10).zero? ? 9000 : 1500))
      msg = LavinMQ::Message.new(Time.utc.to_unix_ms, "ex", "rk", AMQ::Protocol::Properties.new,
        body.bytesize.to_u64, IO::Memory.new(body))
      sp = @positions[id] = @store.push(msg)
      @reference.bytesizes[id] = sp.bytesize.to_u64
      @reference.unread << id
      @trace << "push #{id}"
    end

    private def shift
      env = @store.shift?
      id = env.try { |e| id_of(e) }
      @trace << "shift #{id.inspect}"
      id.should eq @reference.shift?
      @positions[id] = env.segment_position if id && env
    end

    private def first
      id = @store.first?.try { |e| id_of(e) }
      @trace << "first? #{id.inspect}"
      id.should eq @reference.first?
    end

    private def requeue
      id = sample_unacked || return
      @store.requeue(@positions[id])
      @reference.requeue(id)
      @trace << "requeue #{id}"
    end

    private def ack
      id = sample_unacked || return
      @store.delete(@positions[id])
      @reference.ack(id)
      @trace << "ack #{id}"
    end

    private def purge
      max = @rng.rand(0..5)
      purged = @store.purge(max)
      @trace << "purge #{max}: #{purged}"
      expected = 0
      while expected < max && (id = @reference.shift?)
        @reference.ack(id)
        expected += 1
      end
      purged.should eq expected
    end

    # Queue#purge only purges everything this way when nothing is unacked.
    private def purge_all
      return unless @reference.unacked.empty?
      @store.purge_all
      @trace << "purge_all"
      while id = @reference.shift?
        @reference.ack(id)
      end
    end

    private def restart
      @store.close
      @store = LavinMQ::MessageStore.new(@dir, nil)
      @reference.restart
      @trace << "restart"
    end

    # Nothing is closed or truncated, but all that was written to the mmaps
    # survives in the page cache.
    private def crash
      @abandoned << @store
      @store = LavinMQ::MessageStore.new(@dir, nil)
      @reference.restart
      @trace << "crash"
    end

    private def check_counters
      @store.size.should eq @reference.size
      @store.bytesize.should eq @reference.bytesize
      @store.empty?.should eq @reference.size.zero?
    end

    private def sample_unacked : Int32?
      ids = @reference.unacked.to_a.sort!
      ids.sample(@rng) unless ids.empty?
    end

    private def id_of(env) : Int32
      String.new(env.message.body).split(':', 3)[1].to_i
    end
  end
end

describe LavinMQ::MessageStore do
  seed = ENV["SEED"]?.try(&.to_u64) || 1_u64
  seeds = ENV["SEEDS"]?.try(&.to_i) || 100
  steps = ENV["STEPS"]?.try(&.to_i) || 400

  seeds.times do |i|
    it "behaves like a reference queue through random operations and crashes (seed #{seed + i})" do
      old_segment_size = LavinMQ::Config.instance.segment_size
      LavinMQ::Config.instance.segment_size = 8 * 1024 # many segment boundaries
      with_datadir do |dir|
        run = MessageStoreModel::Run.new(dir, seed + i)
        begin
          steps.times { run.step }
        rescue ex
          fail "#{ex.message}\nLast steps:\n#{run.trace}"
        ensure
          run.close
        end
      end
    ensure
      LavinMQ::Config.instance.segment_size = old_segment_size if old_segment_size
    end
  end
end
