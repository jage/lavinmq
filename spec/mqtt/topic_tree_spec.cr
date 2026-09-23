require "./spec_helper"
require "../../src/lavinmq/mqtt/topic_tree"

private def matching(filter : String, topics = %w[a a/b a/b/c b]) : Array(String)
  tree = LavinMQ::MQTT::TopicTree(String).new
  topics.each { |topic| tree.insert(topic, topic) }
  matched = [] of String
  tree.each(filter) { |topic, _entity| matched << topic }
  matched.sort
end

describe LavinMQ::MQTT::TopicTree do
  describe "#each" do
    it "matches the parent level with '#'" do
      matching("a/#").should eq %w[a a/b a/b/c]
      matching("a/b/#").should eq %w[a/b a/b/c]
      matching("+/#").should eq %w[a a/b a/b/c b]
    end
  end
end
