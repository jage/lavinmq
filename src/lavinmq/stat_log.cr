require "json"

module LavinMQ
  # A stat's samples on the GC heap, headed by their capacity so a reader holding the buffer never
  # reads past it, even if the log was resized meanwhile. Atomic: the GC doesn't scan the samples.
  module StatBuffer
    HEADER = 8 # Int32 capacity, padded so Float64 samples stay aligned

    def self.alloc(capacity : Int32, fill : T) : Pointer(UInt8) forall T
      buffer = GC.malloc_atomic(LibC::SizeT.new(HEADER + capacity * sizeof(T))).as(Pointer(UInt8))
      buffer.as(Pointer(Int32)).value = capacity
      samples(buffer, T).to_slice(capacity).fill(fill)
      buffer
    end

    def self.capacity(buffer : Pointer(UInt8)) : Int32
      buffer.as(Pointer(Int32)).value
    end

    def self.samples(buffer : Pointer(UInt8), type : T.class) : Pointer(T) forall T
      (buffer + HEADER).as(Pointer(T))
    end
  end

  # A stat's last value, plus a ring buffer of samples only while the value changes within the
  # window. Without a buffer the log reads as its last value. The ring's head and size are kept by
  # the owner, shared by all its columns. Only the stats loop writes.
  struct StatColumn(T)
    getter last : T
    getter buffer = Pointer(UInt8).null
    @run = 0 # samples in a row equal to last

    def initialize(@last : T)
    end

    def buffered? : Bool
      !@buffer.null?
    end

    # Writes *value* at *tail* of a ring of *capacity*, *window* samples long after this one. Without
    # a buffer, a change only takes one once the history is *established*; before that the log's
    # earlier samples read as the new value
    def record(value : T, tail : Int32, established : Bool, window : Int32, capacity : Int32) : Nil
      if value == @last
        return if @buffer.null?
        StatBuffer.samples(@buffer, T)[tail] = value
        @run += 1
        @buffer = Pointer(UInt8).null if @run >= window # the whole window is the last value
        return
      end
      if buffered?
        StatBuffer.samples(@buffer, T)[tail] = value
      elsif established # earlier samples were all the last value
        buffer = StatBuffer.alloc(capacity, @last)
        StatBuffer.samples(buffer, T)[tail] = value
        Atomic.fence(:release)
        @buffer = buffer
      end
      @run = 1
      @last = value
    end

    # Moves the newest samples to the front of a buffer of *capacity*, so the ring starts at 0
    def resize(head : Int32, size : Int32, capacity : Int32) : Nil
      return if @buffer.null?
      old = StatBuffer.samples(@buffer, T)
      old_capacity = StatBuffer.capacity(@buffer)
      keep = Math.min(size, capacity)
      buffer = StatBuffer.alloc(capacity, @last)
      samples = StatBuffer.samples(buffer, T)
      first = head + size - keep
      keep.times { |i| samples[i] = old[(first + i) % old_capacity] }
      Atomic.fence(:release)
      @buffer = buffer
    end
  end

  # A snapshot of a stat log for readers, the oldest sample first
  struct StatLogView(T)
    include Enumerable(T)

    def initialize(@buffer : Pointer(UInt8), @head : Int32, @size : Int32, @last : T)
    end

    def size : Int32
      @buffer.null? ? @size : Math.min(@size, StatBuffer.capacity(@buffer))
    end

    def each(& : T ->) : Nil
      n = size
      if @buffer.null?
        n.times { yield @last }
        return
      end
      capacity = StatBuffer.capacity(@buffer)
      samples = StatBuffer.samples(@buffer, T)
      i = @head % capacity # the head may be of a resized ring
      n.times do
        yield samples[i]
        i += 1
        i = 0 if i == capacity
      end
    end

    def to_json(json : JSON::Builder) : Nil
      json.array do
        each &.to_json(json)
      end
    end
  end
end
