require "./spec_helper"

# Model-based test of queue and channel accounting through the AMQP protocol:
# random publishes, gets, acks, nacks and rejects (with or without requeue and
# multiple) on two channels, channel closes, purges and restarts, checked
# against a reference model after every step. Each seed picks no length limit,
# x-max-length with drop-head, or x-max-length with reject-publish.
#
# SEED, SEEDS and STEPS override the defaults, e.g. to run it for longer.
module QueueModel
  CHANNELS = 2

  # Messages are ids, which the body carries. Ready messages are the requeued
  # ones first, then the unread ones, both in publish order.
  class Reference
    getter requeued = Array(Int32).new
    getter unread = Deque(Int32).new
    getter unacked = Array(Hash(UInt64, Int32)).new(CHANNELS) { Hash(UInt64, Int32).new }
    @delivered = Set(Int32).new

    # max_length is {limit, reject_publish}
    def initialize(@max_length : {Int32, Bool}?)
    end

    def ready_size
      requeued.size + unread.size
    end

    def unacked_size
      unacked.sum(&.size)
    end

    # Returns false when the publish is refused
    def publish(id) : Bool
      if (ml = @max_length) && ml[1] && ready_size >= ml[0]
        return false
      end
      unread << id
      drop_head
      true
    end

    # The id and redelivered flag of the next message, if any
    def get(ch, tag) : {Int32, Bool}?
      id = requeued.shift? || unread.shift? || return
      redelivered = @delivered.includes?(id)
      @delivered << id
      unacked[ch][tag] = id
      {id, redelivered}
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
      requeued.clear
      unread.clear
    end

    # Closing the connection requeues what its channels had unacked, then
    # every message is unread again
    def restart
      CHANNELS.times { |ch| close_channel(ch) }
      @unread = Deque(Int32).new((requeued + unread.to_a).sort!)
      requeued.clear
      @delivered.clear
    end

    private def requeue(id)
      requeued << id
      requeued.sort!
      drop_head
    end

    private def drop_head
      ml = @max_length || return
      return if ml[1] # reject-publish never drops queued messages
      while ready_size > ml[0]
        requeued.shift? || unread.shift
      end
    end
  end

  class Run
    QUEUE = "model"
    @conn : AMQP::Client::Connection
    @max_length : {Int32, Bool}?
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
      @reference = Reference.new(@max_length)
      @conn = AMQP::Client.new(port: amqp_port(@server)).connect
      @channels = Array.new(CHANNELS) { @conn.channel }
      args = AMQP::Client::Arguments.new
      if ml = @max_length
        args["x-max-length"] = ml[0]
        args["x-overflow"] = ml[1] ? "reject-publish" : "drop-head"
      end
      @channels[0].queue_declare(QUEUE, durable: true, args: args)
      @trace << "max_length=#{@max_length.inspect}"
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
      props = AMQP::Client::Properties.new(delivery_mode: 2_u8)
      confirmed = @channels[c].basic_publish_confirm("id:#{id}", "", QUEUE, props: props)
      @trace << "publish #{id}: #{confirmed}"
      confirmed.should eq @reference.publish(id)
    end

    private def get(c)
      msg = @channels[c].basic_get(QUEUE, no_ack: false)
      got = msg.try { |m| {m.body_io.to_s.split(':')[1].to_i, m.redelivered} }
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
