require "json"

module LavinMQ
  # Read-only value-type view over one column of a per-object stats buffer,
  # or a constant repeated `size` times when `base` is null. Holds the buffer
  # base pointer, never an interior pointer, so the buffer stays GC-alive
  # while a reader iterates even if the owner drops it concurrently.
  struct StatLogView(T)
    include Enumerable(T)

    def initialize(@base : Pointer(T), @offset : Int32, @head : Int32, @size : Int32, @capacity : Int32, @const : T)
    end

    def size : Int32
      @size
    end

    def [](index : Int32) : T
      raise IndexError.new if index >= @size || index < 0
      return @const if @base.null?
      j = @head + index
      j -= @capacity if j >= @capacity
      @base[@offset + j]
    end

    def each(& : T ->) : Nil
      if @base.null?
        @size.times { yield @const }
      else
        @size.times do |i|
          j = @head + i
          j -= @capacity if j >= @capacity
          yield @base[@offset + j]
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
