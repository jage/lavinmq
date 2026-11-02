lib LibGC
  alias ReachableObjectProc = (Void*, SizeT, Void*) ->
  fun enumerate_reachable_objects_inner = GC_enumerate_reachable_objects_inner(proc : ReachableObjectProc, client_data : Void*)
  fun get_kind_and_size = GC_get_kind_and_size(p : Void*, psize : SizeT*) : Int
end

module LavinMQ
  module Debug
    # GC object kind of pointer-free objects (GC_malloc_atomic), the GC never scans them
    PTRFREE_KIND = 0

    # Runs the block with all other threads stopped and the GC allocation lock held.
    #
    # The block must not allocate GC memory, take locks other threads may hold (including
    # malloc's), or raise. Store results in a `RawBuffer`.
    def self.with_world_stopped(& : -> Nil) : Time::Span
      start = Time.instant
      GC.stop_world
      begin
        yield
      ensure
        GC.start_world
      end
      Time.instant - start
    end

    # Visits objects of `Debug.each_reachable_object`. Allocate it before the world is
    # stopped; `visit` must not allocate or raise.
    abstract class Visitor
      abstract def visit(obj : Void*, bytes : UInt64, scanned : Bool) : Nil
    end

    @@visitor : Visitor?

    # Walks every object the last collection marked reachable. Must run with the world
    # stopped.
    def self.each_reachable_object(visitor : Visitor) : Nil
      @@visitor = visitor
      LibGC.enumerate_reachable_objects_inner(->(obj : Void*, bytes : LibC::SizeT, _data : Void*) {
        if v = @@visitor
          v.visit(obj, bytes.to_u64, LibGC.get_kind_and_size(obj, Pointer(LibC::SizeT).null) != PTRFREE_KIND)
        end
        nil
      }, Pointer(Void).null)
      @@visitor = nil
    end

    # An array outside the GC heap, for use while the world is stopped: the pages are
    # reserved up front and only touched pages use memory. Not scanned by the GC, so
    # values must not be the only reference to a live object.
    class RawBuffer(T)
      getter size = 0
      getter capacity : Int32

      def initialize(@capacity : Int32)
        bytes = LibC::SizeT.new(@capacity) * sizeof(T)
        ptr = LibC.mmap(nil, bytes, LibC::PROT_READ | LibC::PROT_WRITE, LibC::MAP_PRIVATE | LibC::MAP_ANON, -1, 0)
        raise RuntimeError.from_errno("mmap") if ptr == LibC::MAP_FAILED
        @ptr = ptr.as(T*)
      end

      # Returns false when full
      def push(value : T) : Bool
        return false if @size >= @capacity
        @ptr[@size] = value
        @size += 1
        true
      end

      def clear : Nil
        @size = 0
      end

      def [](i : Int) : T
        @ptr[i]
      end

      def to_unsafe : T*
        @ptr
      end

      def to_slice : Slice(T)
        Slice.new(@ptr, @size, read_only: true)
      end

      def each(& : T ->)
        @size.times { |i| yield @ptr[i] }
      end

      def full? : Bool
        @size >= @capacity
      end

      # Heapsort: in place, doesn't allocate (the stdlib sorts capture their block)
      def sort_by!(& : T -> UInt64) : Nil
        n = @size
        (n // 2 - 1).downto(0) { |i| sift_down(i, n) { |v| yield v } }
        (n - 1).downto(1) do |last|
          @ptr.swap(0, last)
          sift_down(0, last) { |v| yield v }
        end
      end

      private def sift_down(root : Int32, n : Int32, & : T -> UInt64) : Nil
        loop do
          child = 2 * root + 1
          break if child >= n
          child += 1 if child + 1 < n && (yield @ptr[child]) < (yield @ptr[child + 1])
          break unless (yield @ptr[root]) < (yield @ptr[child])
          @ptr.swap(root, child)
          root = child
        end
      end

      def finalize
        LibC.munmap(@ptr.as(Void*), LibC::SizeT.new(@capacity) * sizeof(T))
      end
    end
  end
end
