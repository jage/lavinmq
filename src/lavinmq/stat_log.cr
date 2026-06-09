require "json"

module LavinMQ
  # Read-only value-type view over one stat column's ring buffer, or a
  # constant repeated `size` times when `base` is null. Holding `base` keeps
  # the buffer alive for the GC even if the owner drops or swaps the column
  # while a reader iterates.
  struct StatLogView(T)
    include Enumerable(T)

    def initialize(@base : Pointer(T), @head : Int32, @size : Int32, @capacity : Int32, @const : T)
    end

    def size : Int32
      @size
    end

    def [](index : Int32) : T
      raise IndexError.new if index >= @size || index < 0
      return @const if @base.null?
      slot = @head + index
      slot -= @capacity if slot >= @capacity
      @base[slot]
    end

    def each(& : T ->) : Nil
      if @base.null?
        @size.times { yield @const }
      else
        @size.times do |i|
          slot = @head + i
          slot -= @capacity if slot >= @capacity
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
      arr = Array(T).new(@size)
      each { |v| arr << v }
      arr
    end
  end
end
