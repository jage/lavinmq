require "./spec_helper"

describe LavinMQ::MQTT::Session do
  describe ".next_packet_id" do
    it "follows the previous id" do
      LavinMQ::MQTT::Session.next_packet_id(7u16) { false }.should eq 8u16
    end

    # Packet identifiers are non-zero [MQTT-2.3.1-1]. The wrap-around used to
    # hand out 0 after 65535.
    it "wraps around to 1, never 0" do
      LavinMQ::MQTT::Session.next_packet_id(UInt16::MAX) { false }.should eq 1u16
    end

    it "skips ids still in flight" do
      in_flight = Set{UInt16::MAX, 1u16, 2u16}
      LavinMQ::MQTT::Session.next_packet_id(UInt16::MAX - 1) { |id| in_flight.includes?(id) }.should eq 3u16
    end

    it "returns nil when every id is in flight" do
      LavinMQ::MQTT::Session.next_packet_id(5u16) { true }.should be_nil
      LavinMQ::MQTT::Session.next_packet_id(0u16) { true }.should be_nil
    end
  end
end
