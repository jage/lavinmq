require "./spec_helper"

# Model-based test of a persistent MQTT session: a publisher sends QoS 0 and 1
# messages while a clean_session=false subscriber connects, disconnects,
# resubscribes with another QoS and acks in any order, and the broker
# restarts. Deliveries, their order, QoS, DUP and packet ids, and the session's
# counters are checked against a reference model after every step. The model
# encodes LavinMQ's choices where MQTT 3.1.1 leaves room or LavinMQ deviates:
#
# * a message is delivered with the QoS of the matching subscription
# * QoS 0 messages for an offline session are dropped
# * unacked messages are requeued on disconnect and resent with new ids
# * at the inflight limit nothing, not even QoS 0, overtakes the queue head
# * DUP isn't set for the first delivery after a restart
#
# SEED, SEEDS and STEPS override the defaults, e.g. to run it for longer.
module MqttSessionModel
  TOPIC = "model/t"

  # Messages are ids, which the payload carries
  class Reference
    getter stored = Array({Int32, UInt8}).new  # {id, qos} not yet delivered
    getter in_flight = Hash(UInt16, Int32).new # packet id => id
    getter subscription_qos : UInt8? = nil
    getter? connected = false
    @delivered = Set(Int32).new

    def initialize(@max_inflight : Int32)
    end

    def publish(id)
      qos = @subscription_qos || return
      return if qos.zero? && !connected? # QoS 0 isn't stored for an offline session
      stored << {id, qos}
    end

    def subscribe(qos)
      @subscription_qos = qos
    end

    def connect
      @connected = true
    end

    # Unacked messages are requeued on disconnect, so they are sent again,
    # before anything newer, when the client reconnects
    def disconnect
      @connected = false
      requeued = in_flight.values.map { |id| {id, 1u8} }
      in_flight.clear
      @stored = (requeued + stored).sort_by!(&.first)
    end

    def ack(packet_id)
      in_flight.delete(packet_id)
    end

    # Deliveries aren't persisted, so DUP isn't set for the first delivery
    # after a restart
    def restart
      @delivered.clear
    end

    # Next delivery due as {id, qos, dup}, if the session can send one now
    def next_delivery : {Int32, UInt8, Bool}?
      return unless connected?
      return if in_flight.size >= @max_inflight # blocks QoS 0 behind it too
      id, qos = stored.first? || return
      stored.shift
      dup = qos == 1 && @delivered.includes?(id)
      @delivered << id
      {id, qos, dup}
    end

    def delivered_qos1(packet_id, id)
      in_flight[packet_id] = id
    end
  end

  class Run
    include MqttHelpers
    @subscriber : MQTT::Protocol::IO?
    @subscriber_socket : TCPSocket?
    @publisher : MQTT::Protocol::IO
    @trace = Array(String).new
    @next_id = 0
    @buffered = Deque(MQTT::Protocol::Publish).new # read while waiting for a SubAck

    def initialize(@server : LavinMQ::Server, seed : Int32, max_inflight : Int32)
      @rng = Random.new(seed)
      @reference = Reference.new(max_inflight)
      @publisher = with_client_io(@server)
      connect(@publisher, client_id: "model-publisher", clean_session: true)
      @trace << "max_inflight=#{max_inflight}"
    end

    def step
      case @rng.rand(100)
      when 0...40  then publish
      when 40...60 then ack
      when 60...72 then resubscribe
      when 72...86 then reconnect
      when 86...97 then disconnect_subscriber
      else              restart
      end
      check_deliveries
    end

    def close
      @subscriber.try &.close
      @publisher.close
    end

    def trace
      @trace.last(20).join("\n")
    end

    private def publish
      id = @next_id
      @next_id += 1
      qos = @rng.rand(2).to_u8
      publish(@publisher, topic: TOPIC, payload: "id:#{id}".to_slice, qos: qos)
      if qos.zero? # no PubAck, so a round trip to know it has been routed
        MQTT::Protocol::PingReq.new.to_io(@publisher)
        MQTT::Protocol::Packet.from_io(@publisher).should be_a MQTT::Protocol::PingResp
      end
      @reference.publish(id)
      @trace << "publish #{id} qos #{qos}"
    end

    private def ack
      io = @subscriber || return
      return if @reference.in_flight.empty?
      packet_id = @reference.in_flight.keys.sort!.sample(@rng)
      puback(io, packet_id)
      @reference.ack(packet_id)
      @trace << "puback #{packet_id}"
    end

    private def resubscribe
      io = @subscriber || return
      qos = @rng.rand(2).to_u8
      subscribe(io, topic_filters: mk_topic_filters({TOPIC, qos}), expect_response: false)
      @subscriber_socket.try &.read_timeout = 2.seconds
      loop do
        case packet = MQTT::Protocol::Packet.from_io(io)
        when MQTT::Protocol::SubAck  then break
        when MQTT::Protocol::Publish then @buffered << packet
        else                              raise "unexpected packet #{packet.inspect}"
        end
      end
      @reference.subscribe(qos)
      @trace << "subscribe qos #{qos}"
    end

    private def reconnect
      return if @subscriber
      socket = with_client_socket(@server)
      io = MQTT::Protocol::IO.new(socket)
      connect(io, client_id: "model-subscriber", clean_session: false)
      @subscriber_socket = socket
      @subscriber = io
      @reference.connect
      @trace << "connect"
    end

    private def disconnect_subscriber
      io = @subscriber || return
      disconnect(io)
      io.close
      @subscriber = nil
      @subscriber_socket = nil
      @buffered.clear
      if session = @server.vhosts["/"].session?("mqtt.model-subscriber")
        wait_for { session.client.nil? }
      end
      @reference.disconnect
      @trace << "disconnect"
    end

    # Persistent sessions, their subscriptions and stored messages survive
    private def restart
      disconnect_subscriber
      @publisher.close
      restart_server(@server)
      @reference.restart
      @publisher = with_client_io(@server)
      connect(@publisher, client_id: "model-publisher", clean_session: true)
      @trace << "restart"
    end

    private def check_deliveries
      while expected = @reference.next_delivery
        io = @subscriber || raise "delivery due without a subscriber"
        @subscriber_socket.try &.read_timeout = 2.seconds
        packet = @buffered.shift? || MQTT::Protocol::Packet.from_io(io).as(MQTT::Protocol::Publish)
        got = {String.new(packet.payload).split(':')[1].to_i, packet.qos, packet.dup?}
        @trace << "delivered #{got} packet id #{packet.packet_id.inspect}"
        got.should eq expected
        if packet.qos == 1
          packet_id = packet.packet_id.should_not be_nil
          packet_id.should_not eq 0
          @reference.delivered_qos1(packet_id, got[0])
        end
      end
      return unless session = @server.vhosts["/"].session?("mqtt.model-subscriber")
      wait_for { session.@unacked.size == @reference.in_flight.size }
      session.message_count.should eq @reference.stored.size
      if (io = @subscriber) && (socket = @subscriber_socket)
        socket.read_timeout = 5.milliseconds
        begin
          packet = MQTT::Protocol::Packet.from_io(io)
          raise "unexpected packet #{packet.inspect}"
        rescue IO::TimeoutError
        end
      end
    end
  end
end

module MqttSessionModel
  extend MqttHelpers

  describe LavinMQ::MQTT::Session do
    seed = ENV["SEED"]?.try(&.to_i) || 1
    seeds = ENV["SEEDS"]?.try(&.to_i) || 4
    steps = ENV["STEPS"]?.try(&.to_i) || 80

    seeds.times do |i|
      it "delivers like a reference persistent session through random operations (seed #{seed + i})" do
        max_inflight = (seed + i).even? ? 2 : 65535
        old_max_inflight = LavinMQ::Config.instance.max_inflight_messages
        LavinMQ::Config.instance.max_inflight_messages = max_inflight.to_u16
        with_server do |s|
          run = MqttSessionModel::Run.new(s, seed + i, max_inflight)
          begin
            steps.times { run.step }
          rescue ex
            fail "#{ex.message}\nLast steps:\n#{run.trace}"
          ensure
            run.close
          end
        end
      ensure
        LavinMQ::Config.instance.max_inflight_messages = old_max_inflight if old_max_inflight
      end
    end
  end
end
