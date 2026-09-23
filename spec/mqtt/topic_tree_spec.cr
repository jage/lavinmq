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

    it "doesn't match '$' topics with a leading wildcard" do
      topics = %w[a $SYS/x $x]
      matching("#", topics).should eq %w[a]
      matching("+", topics).should eq %w[a]
      matching("+/x", topics).should be_empty
      matching("$SYS/#", topics).should eq %w[$SYS/x]
      matching("$x", topics).should eq %w[$x]
    end
  end
end
