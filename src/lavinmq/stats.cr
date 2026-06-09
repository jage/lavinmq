require "./config"
require "./stat_log"

module LavinMQ
  module Stats
    # a delta of 0 short-circuits the divide+round; idle counters dominate
    @[AlwaysInline]
    def self.rate(delta : UInt64, interval : Float64) : Float64
      delta.zero? ? 0.0 : (delta / interval).round(1)
    end

    # The release fence orders the fill stores before the caller's pointer
    # publish, so a concurrent reader never observes uninitialized memory.
    def self.materialize_column(const : T, value : T, tail : Int32, cap : Int32) : Pointer(T) forall T
      buf = GC.malloc_atomic(cap * sizeof(T)).as(Pointer(T))
      Slice.new(buf, cap).fill(const)
      buf[tail] = value
      Atomic.fence(:release)
      buf
    end

    # Per-object stats logs with per-column lazy materialization: a column
    # only allocates its history buffer once its value diverges from its
    # constant, all columns share one ring timeline (head/size), and when
    # every column has been constant for a full window the object reverts to
    # constant-folded (all buffers dropped). Readers hold the buffer base, so
    # a concurrently dropped buffer stays GC-alive until the view dies.
    macro rate_stats(stats_keys, log_keys = %w[])
      @_stats_log_capacity : Int32 = Config.instance.stats_log_size
      @_stats_log_head : Int32 = 0
      @_stats_log_size : Int32 = 0
      @_stats_const_run : Int32 = 0
      @_stats_live_cols : Int32 = 0 # materialized columns; 0 => fully constant-folded

      {% for name, i in stats_keys %}
        @{{ name.id }}_count = Atomic(UInt64).new(0_u64)
        @{{ name.id }}_count_prev = 0_u64
        @{{ name.id }}_rate = 0_f64
        @{{ name.id }}_rate_buffer : Pointer(Float64) = Pointer(Float64).null
        def {{ name.id }}_count
          @{{ name.id }}_count.get(:relaxed)
        end

        def {{ name.id }}_log : StatLogView(Float64)
          # read once: update_rates may null it concurrently (revert)
          buf = @{{ name.id }}_rate_buffer
          if buf.null?
            StatLogView(Float64).new(Pointer(Float64).null, 0, @_stats_log_size, @_stats_log_capacity, @{{ name.id }}_rate)
          else
            StatLogView(Float64).new(buf, @_stats_log_head, @_stats_log_size, @_stats_log_capacity, 0_f64)
          end
        end
      {% end %}
      {% for name, j in log_keys %}
        @{{ name.id }}_log_last = 0_u32
        @{{ name.id }}_count_buffer : Pointer(UInt32) = Pointer(UInt32).null
        def {{ name.id }}_log : StatLogView(UInt32)
          buf = @{{ name.id }}_count_buffer
          if buf.null?
            StatLogView(UInt32).new(Pointer(UInt32).null, 0, @_stats_log_size, @_stats_log_capacity, @{{ name.id }}_log_last)
          else
            StatLogView(UInt32).new(buf, @_stats_log_head, @_stats_log_size, @_stats_log_capacity, 0_u32)
          end
        end
      {% end %}

      def stats_constant_folded? : Bool
        @_stats_live_cols == 0
      end

      def stats_details
        {
          {% for name in stats_keys %}
            {{ name.id }}: {{ name.id }}_count,
            {{ name.id }}_details: {
              rate: @{{ name.id }}_rate,
              log:  {{ name.id }}_log,
            },
          {% end %}
        }
      end

      # Like stats_details but without log
      def current_stats_details
        {
          {% for name in stats_keys %}
            {{ name.id }}: {{ name.id }}_count,
            {{ name.id }}_details: { rate: @{{ name.id }}_rate },
          {% end %}
        }
      end

      def update_rates : Nil
        # float seconds: a sub-second stats_interval must not truncate to 0
        interval = Config.instance.stats_interval / 1000.0
        cap = @_stats_log_capacity
        # ring slot for this sweep's sample; head/size advance below
        tail = @_stats_log_head + @_stats_log_size
        tail -= cap if tail >= cap
        established = @_stats_log_size > 0
        diverged = false

        {% for name, i in stats_keys %}
          count = @{{ name.id }}_count.get(:relaxed)
          rate = Stats.rate(count - @{{ name.id }}_count_prev, interval)
          diverged = true if _stats_store_column(pointerof(@{{ name.id }}_rate_buffer), @{{ name.id }}_rate, rate, tail, cap, established)
          @{{ name.id }}_rate = rate
          @{{ name.id }}_count_prev = count
        {% end %}
        {% for name, j in log_keys %}
          value = {{ name.id }}
          diverged = true if _stats_store_column(pointerof(@{{ name.id }}_count_buffer), @{{ name.id }}_log_last, value, tail, cap, established)
          @{{ name.id }}_log_last = value
        {% end %}

        # nothing materialized: stay constant-folded, just count the window
        if @_stats_live_cols.zero?
          @_stats_log_size += 1 if @_stats_log_size < cap
          return
        end

        _stats_advance_window(cap)
        if diverged
          @_stats_const_run = 1
        else
          @_stats_const_run += 1
          _stats_fold_constant(cap) if @_stats_const_run >= cap
        end
      end

      # Record this sweep's value into the column behind `col`. A constant
      # column (null buffer) materializes on the first diverging value,
      # otherwise stays buffer-free. Returns whether the value diverged.
      @[AlwaysInline]
      private def _stats_store_column(col : Pointer(Pointer(T)), prev : T, value : T, tail : Int32, cap : Int32, established : Bool) : Bool forall T
        buf = col.value
        if buf.null?
          return false unless established && value != prev
          col.value = Stats.materialize_column(prev, value, tail, cap)
          @_stats_live_cols += 1
          true
        else
          buf[tail] = value
          value != prev
        end
      end

      # Slide the shared ring timeline one slot forward.
      @[AlwaysInline]
      private def _stats_advance_window(cap : Int32) : Nil
        if @_stats_log_size < cap
          @_stats_log_size += 1
        else
          @_stats_log_head += 1
          @_stats_log_head -= cap if @_stats_log_head >= cap
        end
      end

      # Every column has been constant for a full window: drop all buffers
      # and serve the whole log as repeated constants again.
      private def _stats_fold_constant(cap : Int32) : Nil
        {% for name, i in stats_keys %}
          @{{ name.id }}_rate_buffer = Pointer(Float64).null
        {% end %}
        {% for name, j in log_keys %}
          @{{ name.id }}_count_buffer = Pointer(UInt32).null
        {% end %}
        @_stats_live_cols = 0
        @_stats_log_head = 0
        @_stats_log_size = cap
        @_stats_const_run = 0
      end

    end
  end
end
