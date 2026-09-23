require "./spec_helper"
require "../../src/lavinmq/mqtt/subscription_tree"
require "../../src/lavinmq/mqtt/topic_tree"

# Model-based tests: random subscribes, unsubscribes and retained topics,
# checked against matching every filter one by one by MQTT 3.1.1 section 4.7,
# the specification verification/LavinMQ/MqttTopic.lean proves the per-filter
# matching against.
module MqttMatchingModel
  extend self

  # The trees compare sessions by identity, as they do MQTT::Session objects
  SESSIONS = %w[s0 s1 s2 s3]

  def matches?(filter : String, topic : String) : Bool
    # [MQTT-4.7.2-1]
    return false if topic.starts_with?('$') && (filter.starts_with?('#') || filter.starts_with?('+'))
    matches?(filter.split('/'), topic.split('/'))
  end

  private def matches?(filter : Array(String), topic : Array(String)) : Bool
    return topic.empty? if filter.empty?
    case filter.first
    when "#" then true
    when "+" then !topic.empty? && matches?(filter[1..], topic[1..])
    else          !topic.empty? && filter.first == topic.first && matches?(filter[1..], topic[1..])
    end
  end

  # Topic names and filters are at least one character [MQTT-4.7.3-1]
  def topic(rng) : String
    loop do
      topic = Array.new(rng.rand(1..4)) { ["a", "b", "", "$x", "ö"].sample(rng) }.join('/')
      return topic unless topic.empty?
    end
  end

  def filter(rng) : String
    levels = Array.new(rng.rand(1..4)) { ["a", "b", "", "+", "$x", "ö"].sample(rng) }
    levels << "#" if rng.rand(3).zero?
    filter = levels.join('/')
    filter.empty? ? "#" : filter
  end
end

describe LavinMQ::MQTT::SubscriptionTree do
  it "matches like the specification through random subscribes and unsubscribes" do
    300.times do |run|
      rng = Random.new(run)
      tree = LavinMQ::MQTT::SubscriptionTree(String).new
      subscriptions = Hash({String, String}, UInt8).new # {session, filter} => qos
      200.times do
        case rng.rand(10)
        when 0..4
          session = MqttMatchingModel::SESSIONS.sample(rng)
          filter = MqttMatchingModel.filter(rng)
          qos = rng.rand(2).to_u8
          tree.subscribe(filter, session, qos)
          subscriptions[{session, filter}] = qos
        when 5..6
          next if subscriptions.empty?
          session, filter = subscriptions.keys.sample(rng)
          tree.unsubscribe(filter, session)
          subscriptions.delete({session, filter})
        else
          topic = MqttMatchingModel.topic(rng)
          got = Set({String, String, UInt8}).new
          tree.each_entry(topic) { |session, qos, filter| got << {session, filter, qos} }
          expected = subscriptions.compact_map do |(session, filter), qos|
            {session, filter, qos} if MqttMatchingModel.matches?(filter, topic)
          end.to_set
          unless got == expected
            fail "run #{run}, topic #{topic.inspect}: missing #{(expected - got).to_a}, extra #{(got - expected).to_a}"
          end
          tree.size.should eq subscriptions.size
          tree.empty?.should eq subscriptions.empty?
        end
      end
    end
  end
end

describe LavinMQ::MQTT::TopicTree do
  it "finds retained topics like the specification through random inserts and deletes" do
    300.times do |run|
      rng = Random.new(run)
      tree = LavinMQ::MQTT::TopicTree(String).new
      retained = Set(String).new
      200.times do
        case rng.rand(10)
        when 0..4
          topic = MqttMatchingModel.topic(rng)
          tree.insert(topic, topic)
          retained << topic
        when 5..6
          next if retained.empty?
          topic = retained.to_a.sample(rng)
          tree.delete(topic)
          retained.delete(topic)
        else
          filter = MqttMatchingModel.filter(rng)
          got = Set(String).new
          tree.each(filter) { |topic, _entity| got << topic }
          expected = retained.select { |topic| MqttMatchingModel.matches?(filter, topic) }.to_set
          unless got == expected
            fail "run #{run}, filter #{filter.inspect}: missing #{(expected - got).to_a}, extra #{(got - expected).to_a}"
          end
          tree.size.should eq retained.size
        end
      end
    end
  end
end
