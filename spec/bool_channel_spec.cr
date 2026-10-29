require "spec"
require "wait_group"
require "../src/lavinmq/bool_channel"

describe BoolChannel do
  # set updates the value and then switches which channel is active, so two
  # concurrent sets with different values could leave the value and the
  # active channel disagreeing, waking or blocking waiters wrongly
  it "keeps the active channel in sync with the value under concurrent sets" do
    ctx = Fiber::ExecutionContext::Parallel.new("bool-channel", 4)
    mismatches = 0
    deadline = Time.instant + 5.seconds
    2_000.times do
      break if Time.instant >= deadline
      bc = BoolChannel.new(false)
      wg = WaitGroup.new
      4.times do |i|
        wg.add(1)
        ctx.spawn do
          500.times { i.even? ? bc.set(true) : bc.swap(false) }
        ensure
          wg.done
        end
      end
      wg.wait
      active = select
      when bc.when_true.receive
        true
      when bc.when_false.receive
        false
      else
        nil
      end
      mismatches += 1 unless active == bc.value
    end
    mismatches.should eq 0
  end

  it "makes a channel on first use that reflects the value set before it" do
    bc = BoolChannel.new(false)
    bc.set(true)
    select
    when bc.when_true.receive
    when timeout 1.second
      fail "when_true should be active"
    end
    select
    when bc.when_false.receive
      fail "when_false should not be active"
    else
    end
  end

  # As with channels made up front: the active one still yields, the other raises
  it "makes a channel on first use that is closed when the BoolChannel was" do
    bc = BoolChannel.new(true)
    bc.close
    bc.when_true.receive.should be_nil
    expect_raises(Channel::ClosedError) { bc.when_false.receive }
  end

  it "wakes a waiter on a channel made before the value changes" do
    bc = BoolChannel.new(false)
    woken = Channel(Nil).new
    spawn do
      bc.when_true.receive
      woken.send nil
    end
    Fiber.yield
    bc.set(true)
    select
    when woken.receive
    when timeout 1.second
      fail "waiter should wake"
    end
  end
end
