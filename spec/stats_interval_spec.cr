require "./spec_helper"

private def with_stats_interval(ms : Int32, &)
  cfg = LavinMQ::Config.instance
  orig = cfg.stats_interval
  begin
    cfg.stats_interval = ms
    yield
  ensure
    cfg.stats_interval = orig
  end
end

private def with_stats_log_size(size : Int32, &)
  cfg = LavinMQ::Config.instance
  orig = cfg.stats_log_size
  begin
    cfg.stats_log_size = size
    yield
  ensure
    cfg.stats_log_size = orig
  end
end

module LavinMQ
  private class LogProbe
    include Stats
    rate_stats({"x"}, {"g"})
    property g = 0_u32

    def bump(n : UInt64)
      @x_count.add(n)
    end

    def buffered? : Bool
      @x_log.buffered? || @g_log.buffered?
    end
  end

  private class IntervalProbe
    include Stats
    rate_stats({"x"})

    def bump(n : UInt64)
      @x_count.add(n)
    end

    def x_rate
      @x_log.last
    end
  end

  describe Server do
    describe "#update_system_metrics" do
      it "yields finite rates with sub-second stats_interval" do
        with_stats_interval(500) do
          with_amqp_server do |s|
            s.update_system_metrics(nil)
            s.update_system_metrics(nil)
            {s.user_time_log, s.sys_time_log, s.blocks_out_log, s.blocks_in_log}.each do |log|
              log.each &.finite?.should be_true
            end
          end
        end
      end
    end
  end

  describe Server do
    it "keeps checking free disk space while out of file descriptors" do
      with_stats_interval(50) do
        with_amqp_server do |s|
          without_free_file_descriptors do
            # Publishers are stopped when the disk is about to fill up
            size = s.disk_free_log.size
            wait_for(timeout: 5.seconds) { s.disk_free_log.size > size }
          end
          size = s.rss_log.size
          wait_for { s.rss_log.size > size }
        end
      end
    end
  end

  describe Stats do
    describe "#update_rates" do
      [1, 50, 250, 500, 999, 1000, 5000, 30_000].each do |ms|
        it "yields finite rates with stats_interval=#{ms}ms" do
          with_stats_interval(ms) do
            p = IntervalProbe.new
            p.update_rates
            p.x_rate.finite?.should be_true
            p.x_rate.should eq 0.0
            p.bump(1234_u64)
            p.update_rates
            p.x_rate.finite?.should be_true
            p.x_rate.should be > 0.0
          end
        end
      end

      it "reports events-per-second independent of the sampling interval" do
        {500 => 100.0, 1000 => 50.0, 5000 => 10.0}.each do |ms, expected|
          with_stats_interval(ms) do
            p = IntervalProbe.new
            p.update_rates
            p.bump(50_u64)
            p.update_rates
            p.x_rate.should eq expected
          end
        end
      end
    end

    describe "logs" do
      it "read the same as a deque of every sample, also across resizes" do
        with_stats_interval(1000) do
          rng = Random.new(42)
          p = LogProbe.new
          rates = Deque(Float64).new
          gauges = Deque(UInt32).new
          capacity = 8
          300.times do |tick|
            capacity = {3, 8, 16}.sample(rng) if tick % 50 == 49
            with_stats_log_size(capacity) do
              # Long idle runs between bursts, so buffers come and go
              if (tick // 20).odd? && rng.rand(3).zero?
                p.bump(rng.rand(1_u64..5_u64))
                p.g = rng.rand(4_u32)
              end
              before = p.x_count
              p.update_rates
              rates.push(p.current_stats_details[:x_details][:rate])
              gauges.push(p.g)
              until rates.size <= capacity
                rates.shift
              end
              until gauges.size <= capacity
                gauges.shift
              end
              p.x_log.to_a.should eq rates.to_a
              p.g_log.to_a.should eq gauges.to_a
              p.x_count.should eq before
            end
          end
        end
      end

      it "only buffer while the value changes within the window" do
        with_stats_log_size(4) do
          p = LogProbe.new
          6.times { p.update_rates }
          p.buffered?.should be_false
          p.x_log.to_a.should eq [0.0] * 4
          p.g = 7_u32
          p.update_rates
          p.buffered?.should be_true
          p.g_log.to_a.should eq [0_u32, 0_u32, 0_u32, 7_u32]
          3.times { p.update_rates }
          p.buffered?.should be_false
          p.g_log.to_a.should eq [7_u32] * 4
        end
      end

      it "starts with the first sample without a buffer" do
        with_stats_log_size(4) do
          p = LogProbe.new
          p.g = 3_u32
          p.update_rates
          p.buffered?.should be_false
          p.g_log.to_a.should eq [3_u32]
        end
      end

      it "keep a view readable after its buffer is dropped or resized" do
        with_stats_log_size(4) do
          p = LogProbe.new
          p.update_rates
          p.g = 1_u32
          p.update_rates
          view = p.g_log
          with_stats_log_size(2) { p.update_rates }
          5.times { p.update_rates }
          p.buffered?.should be_false
          GC.collect
          view.to_a.should eq [0_u32, 1_u32]
        end
      end
    end
  end
end
