require "./spec_helper"

# Model-based test of stream consumers: random publishes, and consumers
# started from first, next, an absolute or a negative offset with random
# prefetch, acked in any order, cancelled and restarted with the broker.
# Every delivery's tag and x-stream-offset is checked against a reference
# model. Offset tracking is left out: it stores the consumer's read position
# on any ack, which skips messages delivered but never acked.
#
# SEED, SEEDS and STEPS override the defaults, e.g. to run it for longer.
module StreamModel
  QUEUE = "stream-model"

  # A stream is its published messages; message i has offset i + 1. Each
  # consumer reads from its start offset, holding at most prefetch unacked.
  class Reference
    getter published = 0i64

    def publish
      @published += 1
    end

    def start_offset(arg) : Int64
      case arg
      when "first" then 1i64
      when "next"  then @published + 1
      when Int64
        if arg.negative?
          Math.max(1i64, @published + arg + 1)
        elsif arg > @published
          @published + 1
        else
          Math.max(arg, 1i64)
        end
      else raise "unexpected offset #{arg}"
      end
    end
  end

  class Consumer
    getter next_offset : Int64
    getter unacked = Array({UInt64, Int64}).new # {delivery tag, offset}
    @next_tag = 1u64

    def initialize(@next_offset, @prefetch : Int32)
    end

    # Offsets due now
    def due(published) : Array({UInt64, Int64})
      out = Array({UInt64, Int64}).new
      while unacked.size < @prefetch && @next_offset <= published
        d = {@next_tag, @next_offset}
        @next_tag += 1
        @next_offset += 1
        unacked << d
        out << d
      end
      out
    end
  end

  class Run
    @conn : AMQP::Client::Connection
    @pub : AMQP::Client::Channel
    @consumers = Array({AMQP::Client::Channel, Consumer, ::Channel(AMQP::Client::DeliverMessage)}).new
    @trace = Array(String).new

    def initialize(@server : LavinMQ::Server, seed : Int32)
      @rng = Random.new(seed)
      @reference = Reference.new
      @conn = AMQP::Client.new(port: amqp_port(@server)).connect
      @pub = @conn.channel
      @pub.queue_declare(QUEUE, durable: true, args: AMQP::Client::Arguments.new({"x-queue-type" => "stream"}))
      consume("first") if seed.odd? # the stream is only empty before the first publish
    end

    def step
      case @rng.rand(100)
      when 0...40  then publish
      when 40...65 then ack
      when 65...80 then consume
      when 80...92 then cancel
      else              restart
      end
      check
    end

    def close
      @conn.close
      @server.vhosts["/"].delete_queue(QUEUE)
    end

    def trace
      @trace.last(20).join("\n")
    end

    private def publish
      @rng.rand(1..3).times do
        @pub.basic_publish_confirm("m", "", QUEUE).should be_true
        @reference.publish
      end
      @trace << "published up to #{@reference.published}"
    end

    private def consume(arg : String | Int64 = random_start)
      return if @consumers.size >= 3
      prefetch = @rng.rand(1..3)
      ch = @conn.channel
      ch.prefetch(prefetch.to_u16)
      deliveries = ::Channel(AMQP::Client::DeliverMessage).new(64)
      ch.basic_consume(QUEUE, no_ack: false, block: false,
        args: AMQP::Client::Arguments.new({"x-stream-offset" => arg})) { |m| deliveries.send m }
      @consumers << {ch, Consumer.new(@reference.start_offset(arg), prefetch), deliveries}
      @trace << "consume #{@consumers.size - 1} from #{arg.inspect} prefetch #{prefetch}"
    end

    private def random_start : String | Int64
      case @rng.rand(4)
      when 0 then "first"
      when 1 then "next"
      when 2 then @rng.rand(0i64..@reference.published + 2)
      else        -@rng.rand(1i64..@reference.published + 2)
      end
    end

    private def ack
      return if @consumers.empty?
      i = @rng.rand(@consumers.size)
      ch, consumer, _ = @consumers[i]
      return if consumer.unacked.empty?
      tag, offset = consumer.unacked.sample(@rng)
      ch.basic_ack(tag)
      consumer.unacked.delete({tag, offset})
      @trace << "ack #{i} offset #{offset}"
    end

    private def cancel
      return if @consumers.empty?
      i = @rng.rand(@consumers.size)
      ch, _, _ = @consumers.delete_at(i)
      ch.close
      @trace << "cancel #{i}"
    end

    private def restart
      @conn.close
      @consumers.clear
      restart_server(@server)
      @conn = AMQP::Client.new(port: amqp_port(@server)).connect
      @pub = @conn.channel
      @trace << "restart"
    end

    private def check
      @consumers.each_with_index do |(_, consumer, deliveries), i|
        consumer.due(@reference.published).each do |tag, offset|
          select
          when msg = deliveries.receive
            got = {msg.delivery_tag, msg.properties.headers.try(&.["x-stream-offset"]?)}
            @trace << "consumer #{i} got #{got}"
            got.should eq({tag, offset})
          when timeout(2.seconds)
            raise "consumer #{i}: no delivery, expected offset #{offset}"
          end
        end
      end
      sleep 5.milliseconds
      @consumers.each_with_index do |(_, _, deliveries), i|
        if msg = deliveries.try_receive?
          raise "consumer #{i}: unexpected delivery at offset #{msg.properties.headers.try(&.["x-stream-offset"]?)}"
        end
      end
    end
  end
end

describe LavinMQ::AMQP::Stream do
  seed = ENV["SEED"]?.try(&.to_i) || 1
  seeds = ENV["SEEDS"]?.try(&.to_i) || 6
  steps = ENV["STEPS"]?.try(&.to_i) || 80

  seeds.times do |i|
    it "delivers offsets like a reference stream through random operations (seed #{seed + i})" do
      with_amqp_server do |s|
        run = StreamModel::Run.new(s, seed + i)
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
