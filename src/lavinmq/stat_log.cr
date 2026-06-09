require "json"

module LavinMQ
  # Read-only value-type view over one stat column's ring buffer, or a
  # constant repeated `size` times when `base` is null. Holding `base` keeps
  # the buffer alive for the GC even if the owner drops or swaps the column
  # while a reader iterates.
  #
  # The ring capacity is self-described in the allocation itself (`base[-1]`).
  # A reader may pair a freshly swapped buffer with stale head/size/capacity,
  # so every index is clamped to `base[-1]` and the shared metadata is treated
  # as a hint, never as a trusted bound.
  struct StatLogView(T)
    include Enumerable(T)

    def initialize(@base : Pointer(T), @head : Int32, @size : Int32, @capacity : Int32, @const : T)
    end

    # Real ring capacity, self-described in the buffer's slot -1 (same allocation
    # as `base`) so it is always consistent with `base` regardless of metadata.
    private def alloc_cap : Int32
      @base.null? ? @capacity : @base[-1].to_i
    end

    def size : Int32
      @base.null? ? @size : Math.min(@size, alloc_cap)
    end

    def [](index : Int32) : T
      raise IndexError.new if index < 0 || index >= size
      return @const if @base.null?
      cap = alloc_cap
      raise IndexError.new if cap <= 0
      slot = @head % cap + index
      slot -= cap if slot >= cap
      @base[slot]
    end

    def each(& : T ->) : Nil
      if @base.null?
        @size.times { yield @const }
      else
        cap = alloc_cap
        return if cap <= 0
        first = @head % cap
        Math.min(@size, cap).times do |i|
          slot = first + i
          slot -= cap if slot >= cap
          yield @base[slot]
        end
      end
    end

    def to_json(json : JSON::Builder) : Nil
      json.array do
        each(&.to_json(json))
      end
    end

    def to_a : Array(T)
      arr = Array(T).new(size)
      each { |v| arr << v }
      arr
    end
  end
end
