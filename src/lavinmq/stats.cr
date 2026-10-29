require "./stat_log"

module LavinMQ
  module Stats
    # Every stat keeps its last value; its history is only buffered while the value changes, so an
    # idle object's logs read as their last value repeated. All columns share one ring position.
    macro rate_stats(stats_keys, log_keys = %w[])
      {% stats_keys = stats_keys.resolve if stats_keys.is_a?(Path) %}
      @_stats_log_head = Atomic(Int32).new(0) # read by views on any thread
      @_stats_log_size = Atomic(Int32).new(0)
      @_stats_log_capacity : Int32 = Config.instance.stats_log_size
      @_stats_buffered = false # whether any column had a buffer after the last update
      {% for name in stats_keys %}
        @{{ name.id }}_count = Atomic(UInt64).new(0_u64)
        @{{ name.id }}_count_prev = 0_u64
        @{{ name.id }}_log = StatColumn(Float64).new(0_f64)
        def {{ name.id }}_count
          @{{ name.id }}_count.get(:relaxed)
        end

        def {{ name.id }}_log : StatLogView(Float64)
          _stats_view(@{{ name.id }}_log)
        end
      {% end %}
      {% for name in log_keys %}
        @{{ name.id }}_log = StatColumn(UInt32).new(0_u32)

        def {{ name.id }}_log : StatLogView(UInt32)
          _stats_view(@{{ name.id }}_log)
        end
      {% end %}

      private def _stats_view(column : StatColumn(T)) : StatLogView(T) forall T
        StatLogView.new(column.buffer, @_stats_log_head.get(:acquire), @_stats_log_size.get(:acquire), column.last)
      end

      def stats_details
        {
          {% for name in stats_keys %}
            {{ name.id }}: {{ name.id }}_count,
            {{ name.id }}_details: {
              rate: @{{ name.id }}_log.last,
              log: {{ name.id }}_log
            },
          {% end %}
        }
      end

      # Like stats_details but without log
      def current_stats_details
        {
          {% for name in stats_keys %}
            {{ name.id }}: {{ name.id }}_count,
            {{ name.id }}_details: { rate: @{{ name.id }}_log.last },
          {% end %}
        }
      end

      def update_rates : Nil
        interval = Config.instance.stats_interval / 1000.0
        capacity = Config.instance.stats_log_size
        size = @_stats_log_size.get(:relaxed)
        if !@_stats_buffered && capacity == @_stats_log_capacity && _stats_idle?
          @_stats_log_size.set(size + 1, :release) if size < capacity
          return
        end
        _stats_resize(capacity) if capacity != @_stats_log_capacity
        head = @_stats_log_head.get(:relaxed)
        size = @_stats_log_size.get(:relaxed)
        tail = head + size
        tail -= capacity if tail >= capacity
        window = size < capacity ? size + 1 : capacity
        buffered = false
        {% for name in stats_keys %}
          {{ name.id }}_count = @{{ name.id }}_count.get(:relaxed)
          {{ name.id }}_rate = 0_f64
          if {{ name.id }}_count != @{{ name.id }}_count_prev # idle objects don't dirty their cache lines
            {{ name.id }}_rate = (({{ name.id }}_count - @{{ name.id }}_count_prev) / interval).round(1)
            @{{ name.id }}_count_prev = {{ name.id }}_count
          end
          @{{ name.id }}_log.record({{ name.id }}_rate, tail, size, window, capacity)
          buffered ||= @{{ name.id }}_log.buffered?
        {% end %}
        {% for name in log_keys %}
          @{{ name.id }}_log.record({{ name.id }}, tail, size, window, capacity)
          buffered ||= @{{ name.id }}_log.buffered?
        {% end %}
        if size < capacity
          @_stats_log_size.set(size + 1, :release)
        elsif buffered # without buffers the head means nothing
          head += 1
          head = 0 if head == capacity
          @_stats_log_head.set(head, :release)
        end
        @_stats_buffered = buffered
      end

      # Whether this update would only repeat every last value
      private def _stats_idle? : Bool
        {% for name in stats_keys %}
          return false unless @{{ name.id }}_count.get(:relaxed) == @{{ name.id }}_count_prev && @{{ name.id }}_log.last.zero?
        {% end %}
        {% for name in log_keys %}
          return false unless {{ name.id }} == @{{ name.id }}_log.last
        {% end %}
        true
      end

      private def _stats_resize(capacity : Int32) : Nil
        head = @_stats_log_head.get(:relaxed)
        size = @_stats_log_size.get(:relaxed)
        {% for name in stats_keys + log_keys %}
          @{{ name.id }}_log.resize(head, size, capacity)
        {% end %}
        @_stats_log_head.set(0, :release)
        @_stats_log_size.set(Math.min(size, capacity), :release)
        @_stats_log_capacity = capacity
      end
    end
  end
end
