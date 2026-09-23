require "./spec_helper"

# Model-based test of queue and channel accounting through the AMQP protocol:
# random publishes, gets, acks, nacks and rejects (with or without requeue and
# multiple) on two channels, channel closes, purges and restarts, checked
# against a reference model after every step. Each seed picks no length limit,
# x-max-length with drop-head, or x-max-length with reject-publish, and
# whether the queue has priorities and a delivery limit.
#
# SEED, SEEDS and STEPS override the defaults, e.g. to run it for longer.
module QueueModel
  CHANNELS = 2

  MAX_PRIORITY = 3

  # Messages are ids, which the body carries. Ready messages are delivered by
  # priority, then in publish order: a requeued message was published before
  # every unread one of its priority.
  class Reference
    getter ready = Array(Int32).new
    getter unacked = Array(Hash(UInt64, Int32)).new(CHANNELS) { Hash(UInt64, Int32).new }
    @priorities = Hash(Int32, Int32).new
    @deliveries = Hash(Int32, Int32).new
    @delivered = Set(Int32).new

    # max_length is {limit, reject_publish}
    def initialize(@max_length : {Int32, Bool}?, @priority : Bool, @delivery_limit : Int32?)
    end

    def ready_size
      ready.size
    end

    def unacked_size
      unacked.sum(&.size)
    end

    # Returns false when the publish is refused
    def publish(id, priority) : Bool
      if (ml = @max_length) && ml[1] && ready_size >= ml[0]
        return false
      end
      @priorities[id] = @priority ? Math.min(priority, MAX_PRIORITY) : 0
      insert(id)
      drop_head
      true
    end

    # The id, redelivered flag and x-delivery-count of the next message, if any
    def get(ch, tag) : {Int32, Bool, Int32?}?
      id = ready.shift? || return
      redelivered = @delivered.includes?(id)
      @delivered << id
      unacked[ch][tag] = id
      count = nil
      if @delivery_limit
        count = @deliveries.fetch(id, 0)
        @deliveries[id] = count + 1
        count = nil if count.zero?
      end
      {id, redelivered, count}
    end

    def settle(ch, tag, multiple, requeue)
      tags = multiple ? unacked[ch].keys.select(&.<=(tag)).sort! : [tag]
      tags.each do |t|
        id = unacked[ch].delete(t) || next
        requeue(id) if requeue
      end
    end

    def close_channel(ch)
      unacked[ch].keys.sort!.each { |tag| requeue(unacked[ch][tag]) }
      unacked[ch].clear
    end

    def purge
      ready.clear
    end

    # Closing the connection requeues what its channels had unacked, and the
    # queue forgets deliveries when it closes
    def restart
      CHANNELS.times { |ch| close_channel(ch) }
      @delivered.clear
      @deliveries.clear
    end

    private def requeue(id)
      if (limit = @delivery_limit) && @deliveries.fetch(id, 0) > limit
        @deliveries.delete(id)
        return
      end
      insert(id)
      drop_head
    end

    private def insert(id)
      ready << id
      ready.sort_by! { |i| {-@priorities[i], i} }
    end

    private def drop_head
      ml = @max_length || return
      return if ml[1] # reject-publish never drops queued messages
      while ready_size > ml[0]
        ready.shift
      end
    end
  end

  class Run
    QUEUE = "model"
    @conn : AMQP::Client::Connection
    @max_length : {Int32, Bool}?
    @delivery_limit : Int32?
    @priority : Bool
    @channels : Array(AMQP::Client::Channel)
    @trace = Array(String).new
    @next_id = 0

    def initialize(@server : LavinMQ::Server, seed : Int32)
      @rng = Random.new(seed)
      @max_length = case seed % 3
                    when 0 then nil
                    when 1 then {@rng.rand(1..6), false}
                    else        {@rng.rand(1..6), true}
                    end
      @priority = (seed // 3).odd?
      @delivery_limit = (seed // 6).odd? ? @rng.rand(0..2) : nil
      @reference = Reference.new(@max_length, @priority, @delivery_limit)
      @conn = AMQP::Client.new(port: amqp_port(@server)).connect
      @channels = Array.new(CHANNELS) { @conn.channel }
      args = AMQP::Client::Arguments.new
      if ml = @max_length
        args["x-max-length"] = ml[0]
        args["x-overflow"] = ml[1] ? "reject-publish" : "drop-head"
      end
      args["x-max-priority"] = MAX_PRIORITY if @priority
      if limit = @delivery_limit
        args["x-delivery-limit"] = limit
      end
      @channels[0].queue_declare(QUEUE, durable: true, args: args)
      @trace << "max_length=#{@max_length.inspect} priority=#{@priority} delivery_limit=#{@delivery_limit.inspect}"
    end

    def step
      c = @rng.rand(CHANNELS)
      case @rng.rand(100)
      when 0...30  then publish(c)
      when 30...55 then get(c)
      when 55...70 then ack(c)
      when 70...80 then nack(c)
      when 80...88 then reject(c)
      when 88...93 then close_channel(c)
      when 93...96 then purge(c)
      else              restart
      end
      check_counters
    end

    def close
      @conn.close
      @server.vhosts["/"].delete_queue(QUEUE)
    end

    def trace
      @trace.last(20).join("\n")
    end

    private def publish(c)
      id = @next_id
      @next_id += 1
      priority = @rng.rand(0..MAX_PRIORITY + 1) # above max is capped at max
      props = AMQP::Client::Properties.new(delivery_mode: 2_u8, priority: priority.to_u8)
      confirmed = @channels[c].basic_publish_confirm("id:#{id}", "", QUEUE, props: props)
      @trace << "publish #{id} priority #{priority}: #{confirmed}"
      confirmed.should eq @reference.publish(id, priority)
    end

    private def get(c)
      msg = @channels[c].basic_get(QUEUE, no_ack: false)
      got = msg.try do |m|
        count = m.properties.headers.try(&.["x-delivery-count"]?).try(&.as(Int).to_i32)
        {m.body_io.to_s.split(':')[1].to_i, m.redelivered, count}
      end
      @trace << "get ch#{c}: #{got.inspect}"
      got.should eq @reference.get(c, msg.try(&.delivery_tag) || 0u64)
    end

    private def ack(c)
      tag = sample_unacked(c) || return
      multiple = @rng.rand(4).zero?
      @channels[c].basic_ack(tag, multiple: multiple)
      @reference.settle(c, tag, multiple, requeue: false)
      @trace << "ack ch#{c} #{tag} multiple=#{multiple}"
    end

    private def nack(c)
      tag = sample_unacked(c) || return
      multiple = @rng.rand(4).zero?
      requeue = @rng.rand(2).zero?
      @channels[c].basic_nack(tag, requeue: requeue, multiple: multiple)
      @reference.settle(c, tag, multiple, requeue)
      @trace << "nack ch#{c} #{tag} requeue=#{requeue} multiple=#{multiple}"
    end

    private def reject(c)
      tag = sample_unacked(c) || return
      requeue = @rng.rand(2).zero?
      @channels[c].basic_reject(tag, requeue: requeue)
      @reference.settle(c, tag, false, requeue)
      @trace << "reject ch#{c} #{tag} requeue=#{requeue}"
    end

    private def close_channel(c)
      @channels[c].close
      @channels[c] = @conn.channel
      @reference.close_channel(c)
      @trace << "close ch#{c}"
    end

    private def purge(c)
      @channels[c].queue_purge(QUEUE)
      @reference.purge
      @trace << "purge"
    end

    private def restart
      @conn.close
      restart_server(@server)
      @conn = AMQP::Client.new(port: amqp_port(@server)).connect
      @channels = Array.new(CHANNELS) { @conn.channel }
      @reference.restart
      @trace << "restart"
    end

    # A synchronous round trip on every channel first, so the server has
    # processed everything sent on them
    private def check_counters
      @channels.each do |ch|
        ch.queue_declare(QUEUE, passive: true)[:message_count].should eq @reference.ready_size
      end
      queue = @server.vhosts["/"].queue(QUEUE)
      queue.message_count.should eq @reference.ready_size
      queue.unacked_count.should eq @reference.unacked_size
    end

    private def sample_unacked(c) : UInt64?
      tags = @reference.unacked[c].keys.sort!
      tags.sample(@rng) unless tags.empty?
    end
  end
end

describe LavinMQ::AMQP::Queue do
  seed = ENV["SEED"]?.try(&.to_i) || 1
  seeds = ENV["SEEDS"]?.try(&.to_i) || 6
  steps = ENV["STEPS"]?.try(&.to_i) || 150

  seeds.times do |i|
    it "behaves like a reference queue through random operations (seed #{seed + i})" do
      with_amqp_server do |s|
        run = QueueModel::Run.new(s, seed + i)
        begin
          steps.times { run.step }
        rescue ex
          fail "#{ex.message}\nLast steps:\n#{run.trace}"
        ensure
          run.close
        end
      end
    end
  end
end
