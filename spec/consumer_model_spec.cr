require "./spec_helper"

# Model-based test of consumer deliveries: random publishes, acks, nacks and
# rejects, consumes, cancels, prefetch changes, channel closes and restarts on
# one channel, checked against a reference model after every step. Deliveries
# are pushed asynchronously, but once the server settles the consumer holds
# what the model says, in the order it says.
#
# SEED, SEEDS and STEPS override the defaults, e.g. to run it for longer.
module ConsumerModel
  # Messages are ids, which the body carries. basic.qos without global limits
  # each consumer to its own unacked messages, also after a change.
  class Reference
    getter ready = Array(Int32).new
    getter in_flight = Hash(UInt64, {Int32, Int32}).new # delivery tag => {id, consumer}
    @consumer = 0
    getter prefetch : Int32
    getter? consuming = false
    @delivered = Set(Int32).new
    @next_tag = 1u64

    def initialize(@prefetch)
    end

    def publish(id)
      ready << id
      ready.sort!
    end

    # Deliveries the server should push now, as {tag, id, redelivered}
    def deliver : Array({UInt64, Int32, Bool})
      out = Array({UInt64, Int32, Bool}).new
      while consuming? && (prefetch.zero? || consumer_unacked < prefetch) && !ready.empty?
        id = ready.shift
        tag = @next_tag
        @next_tag += 1
        in_flight[tag] = {id, @consumer}
        out << {tag, id, @delivered.includes?(id)}
        @delivered << id
      end
      out
    end

    def settle(tag, multiple, requeue)
      tags = multiple ? in_flight.keys.select(&.<=(tag)).sort! : [tag]
      tags.each do |t|
        id, _ = in_flight.delete(t) || next
        publish(id) if requeue
      end
    end

    # basic.qos without global limits each consumer on its own unacked
    private def consumer_unacked
      in_flight.count { |_, (_, consumer)| consumer == @consumer }
    end

    def consume
      @consuming = true
      @consumer += 1
    end

    # Cancelling keeps what was delivered unacked
    def cancel
      @consuming = false
    end

    def qos(prefetch)
      @prefetch = prefetch
    end

    # A new channel numbers deliveries from 1 again
    def close_channel
      in_flight.each_value { |(id, _)| publish(id) }
      in_flight.clear
      @consuming = false
      @next_tag = 1u64
    end

    def restart
      close_channel
      @delivered.clear
    end
  end

  class Run
    QUEUE = "consumer-model"
    @conn : AMQP::Client::Connection
    @ch : AMQP::Client::Channel
    @deliveries = ::Channel(AMQP::Client::DeliverMessage).new(1024)
    @trace = Array(String).new
    @next_id = 0
    @consumer_tag : String?

    def initialize(@server : LavinMQ::Server, seed : Int32)
      @rng = Random.new(seed)
      @reference = Reference.new(@rng.rand(0..3))
      @conn = AMQP::Client.new(port: amqp_port(@server)).connect
      @ch = open_channel
      @ch.queue_declare(QUEUE, durable: true)
      @trace << "prefetch=#{@reference.prefetch}"
    end

    def step
      case @rng.rand(100)
      when 0...30  then publish
      when 30...50 then ack
      when 50...60 then nack
      when 60...68 then reject
      when 68...78 then consume
      when 78...84 then cancel
      when 84...90 then qos
      when 90...96 then close_channel
      else              restart
      end
      check_deliveries
    end

    def close
      @conn.close
      @server.vhosts["/"].delete_queue(QUEUE)
    end

    def trace
      @trace.last(20).join("\n")
    end

    private def open_channel
      ch = @conn.channel
      ch.prefetch(@reference.prefetch.to_u16) unless @reference.prefetch.zero?
      ch
    end

    private def publish
      id = @next_id
      @next_id += 1
      props = AMQP::Client::Properties.new(delivery_mode: 2_u8)
      @ch.basic_publish_confirm("id:#{id}", "", QUEUE, props: props).should be_true
      @reference.publish(id)
      @trace << "publish #{id}"
    end

    private def ack
      tag = sample_in_flight || return
      multiple = @rng.rand(4).zero?
      @ch.basic_ack(tag, multiple: multiple)
      @reference.settle(tag, multiple, requeue: false)
      @trace << "ack #{tag} multiple=#{multiple}"
    end

    private def nack
      tag = sample_in_flight || return
      multiple = @rng.rand(4).zero?
      requeue = @rng.rand(2).zero?
      @ch.basic_nack(tag, requeue: requeue, multiple: multiple)
      @reference.settle(tag, multiple, requeue)
      @trace << "nack #{tag} requeue=#{requeue} multiple=#{multiple}"
    end

    private def reject
      tag = sample_in_flight || return
      requeue = @rng.rand(2).zero?
      @ch.basic_reject(tag, requeue: requeue)
      @reference.settle(tag, false, requeue)
      @trace << "reject #{tag} requeue=#{requeue}"
    end

    private def consume
      return if @reference.consuming?
      deliveries = @deliveries
      @consumer_tag = @ch.basic_consume(QUEUE, no_ack: false, block: false) do |msg|
        deliveries.send(msg)
      end
      @reference.consume
      @trace << "consume"
    end

    private def cancel
      tag = @consumer_tag || return
      return unless @reference.consuming?
      @ch.basic_cancel(tag)
      @reference.cancel
      @trace << "cancel"
    end

    private def qos
      prefetch = @rng.rand(0..3)
      @ch.prefetch(prefetch.to_u16)
      @reference.qos(prefetch)
      @trace << "qos #{prefetch}"
    end

    private def close_channel
      @ch.close
      @ch = open_channel
      @reference.close_channel
      @trace << "close channel"
    end

    private def restart
      @conn.close
      restart_server(@server)
      @conn = AMQP::Client.new(port: amqp_port(@server)).connect
      @ch = open_channel
      @reference.restart
      @trace << "restart"
    end

    private def check_deliveries
      expected = @reference.deliver
      expected.each do |tag, id, redelivered|
        select
        when msg = @deliveries.receive
          got = {msg.delivery_tag, msg.body_io.to_s.split(':')[1].to_i, msg.redelivered}
          @trace << "delivered #{got}"
          got.should eq({tag, id, redelivered})
        when timeout(2.seconds)
          raise "no delivery, expected #{{tag, id, redelivered}}"
        end
      end
      queue = @server.vhosts["/"].queue(QUEUE)
      wait_for { queue.unacked_count == @reference.in_flight.size }
      @ch.queue_declare(QUEUE, passive: true)[:message_count].should eq @reference.ready.size
      if msg = @deliveries.try_receive?
        raise "unexpected delivery #{msg.delivery_tag} #{msg.body_io}"
      end
    end

    private def sample_in_flight : UInt64?
      tags = @reference.in_flight.keys.sort!
      tags.sample(@rng) unless tags.empty?
    end
  end
end

describe LavinMQ::AMQP::Consumer do
  seed = ENV["SEED"]?.try(&.to_i) || 1
  seeds = ENV["SEEDS"]?.try(&.to_i) || 6
  steps = ENV["STEPS"]?.try(&.to_i) || 100

  seeds.times do |i|
    it "delivers like a reference consumer through random operations (seed #{seed + i})" do
      with_amqp_server do |s|
        run = ConsumerModel::Run.new(s, seed + i)
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
