require "./runtime"
require "./type_table"

module LavinMQ
  module Debug
    # Live heap census and reference scans. Both force a collection and then walk the
    # heap with the world stopped, see docs/debugging.md for their cost.
    module Heap
      MAX_TYPE_ID = 1 << 16
      BUCKETS     = 48

      # Instance sizes by type ID, 0 for IDs not in `TypeTable`, -1 for types of variable
      # size (String). Built once, before any world is stopped.
      class_getter instance_sizes : Slice(Int32) do
        sizes = Slice(Int32).new(MAX_TYPE_ID, 0)
        TypeTable.entries.each do |id, e|
          next unless 0 < id < MAX_TYPE_ID
          sizes[id] = e.name == "String" ? -1 : e.instance_size
        end
        sizes
      end

      # The object's type ID if its first word is one and its GC size fits the type,
      # else 0. Objects without a type header are buffers (of arrays, hashes, deques,
      # strings builders), closures and other raw allocations.
      @[AlwaysInline]
      def self.type_id(obj : Void*, bytes : UInt64, sizes : Slice(Int32)) : Int32
        return 0 if bytes < 4
        id = obj.as(Int32*).value
        return 0 unless 0 < id < MAX_TYPE_ID
        isize = sizes.to_unsafe[id]
        return 0 if isize == 0
        return id if isize < 0 && bytes >= 16
        isize = isize.to_u64
        return 0 if bytes < isize
        bytes - isize <= TypeTable.slack(isize) ? id : 0
      end

      # Objects without a type header are grouped by size class (power of two)
      def self.bucket(bytes : UInt64) : Int32
        Math.min(BUCKETS - 1, 64 - bytes.leading_zeros_count)
      end

      def self.bucket_name(b : Int32) : String
        low = b == 0 ? 0_i64 : 1_i64 << (b - 1)
        "<no type header, #{low}-#{(1_i64 << b) - 1} B>"
      end

      def self.holder_name(id : Int32) : String
        id >= 0 ? (TypeTable.name(id) || "<type #{id}>") : bucket_name(-id - 1)
      end

      record Row, name : String, scanned : Bool, count : Int64, bytes : Int64

      record Census, rows : Array(Row), objects : Int64, bytes : Int64, scanned_bytes : Int64,
        collect : Time::Span, stopped : Time::Span

      private class CensusVisitor < Visitor
        getter count = Slice(Int64).new(MAX_TYPE_ID * 2, 0_i64)
        getter bytes = Slice(Int64).new(MAX_TYPE_ID * 2, 0_i64)
        getter bucket_count = Slice(Int64).new(BUCKETS * 2, 0_i64)
        getter bucket_bytes = Slice(Int64).new(BUCKETS * 2, 0_i64)

        def initialize(@sizes : Slice(Int32))
        end

        def visit(obj : Void*, bytes : UInt64, scanned : Bool) : Nil
          k = scanned ? 1 : 0
          if (id = Heap.type_id(obj, bytes, @sizes)) > 0
            @count.to_unsafe[id * 2 + k] += 1
            @bytes.to_unsafe[id * 2 + k] += bytes.to_i64
          else
            b = Heap.bucket(bytes)
            @bucket_count.to_unsafe[b * 2 + k] += 1
            @bucket_bytes.to_unsafe[b * 2 + k] += bytes.to_i64
          end
        end
      end

      def self.census : Census
        sizes = instance_sizes
        visitor = CensusVisitor.new(sizes)
        start = Time.instant
        GC.collect
        collect = Time.instant - start
        stopped = Debug.with_world_stopped { Debug.each_reachable_object(visitor) }
        rows = [] of Row
        MAX_TYPE_ID.times do |id|
          2.times do |k|
            n = visitor.count[id * 2 + k]
            rows << Row.new(holder_name(id), k == 1, n, visitor.bytes[id * 2 + k]) if n > 0
          end
        end
        BUCKETS.times do |b|
          2.times do |k|
            n = visitor.bucket_count[b * 2 + k]
            rows << Row.new(bucket_name(b), k == 1, n, visitor.bucket_bytes[b * 2 + k]) if n > 0
          end
        end
        rows.sort_by! { |r| -r.bytes }
        Census.new(rows, rows.sum(&.count), rows.sum(&.bytes),
          rows.select(&.scanned).sum(&.bytes), collect, stopped)
      end

      # An object (or address range) whose holders are looked for. *tag* is the caller's.
      record Target, start : UInt64, stop : UInt64, tag : Int32

      enum HolderKind : UInt8
        Heap   # a word in a reachable, scanned heap object
        Stack  # a word in a suspended fiber's stack
        Static # a word in a writable data segment of the executable or a library
      end

      # One word that points into a target. For heap holders *holder* is the object and
      # *offset* the word's offset in it, *holder_type* as `Heap.type_id` or
      # -(size bucket + 1). For stacks *holder* is the fiber object, *offset* the distance
      # from the stack bottom (highest address) and *holder_stack* the stack's lowest
      # address. For statics *holder* is the word's address.
      record Holder, target : Int32, kind : HolderKind, holder : UInt64, offset : Int64,
        holder_type : Int32, holder_stack : UInt64

      # Finds the words that point into *targets* in the reachable heap, the suspended
      # fibers' stacks and the writable data segments. Must run with the world stopped.
      # Returns false if *holders* filled up.
      class Scanner < Visitor
        def initialize(@targets : RawBuffer(Target), @holders : RawBuffer(Holder),
                       @segments : Array({UInt64, UInt64}), @sizes : Slice(Int32))
          @low = 0_u64
          @high = 0_u64
        end

        # Sorts the targets, so all scanning is done while stopped
        def scan : Nil
          return if @targets.size == 0
          @targets.sort_by!(&.start)
          @low = @targets[0].start
          @high = 0_u64
          @targets.each { |t| @high = t.stop if t.stop > @high }
          Debug.each_reachable_object(self)
          scan_stacks
          @segments.each do |low, high|
            scan_range(low, high) { |addr, i| @holders.push(Holder.new(i, :static, addr, 0, 0, 0)) }
          end
        end

        def visit(obj : Void*, bytes : UInt64, scanned : Bool) : Nil
          return unless scanned
          return if obj == self.as(Void*) # its bounds are target addresses
          base = obj.address
          type_id = -1
          scan_range(base, base + bytes) do |addr, i|
            next if @targets.to_unsafe[i].start == base # self reference
            if type_id == -1
              type_id = Heap.type_id(obj, bytes, @sizes)
              type_id = -(Heap.bucket(bytes) + 1) if type_id == 0
            end
            @holders.push(Holder.new(i, :heap, base, (addr - base).to_i64, type_id, 0))
          end
        end

        private def scan_stacks : Nil
          Fiber.unsafe_each do |f|
            # A running fiber's registers and stack pointer aren't known here; the
            # scanning fiber's own stack would only find the scan's own references
            next if f.running? || f.dead?
            stack = f.@stack
            low = f.@context.stack_top.address
            bottom = stack.bottom.address
            scan_range(low, bottom) do |addr, i|
              @holders.push(Holder.new(i, :stack, f.object_id, (bottom - addr).to_i64, 0, stack.pointer.address))
            end
          end
        end

        # Yields the address of each aligned word in [low, high) pointing into a target,
        # and the target's index
        private def scan_range(low : UInt64, high : UInt64, & : UInt64, Int32 ->) : Nil
          addr = (low + 7) & ~7_u64
          while addr + 8 <= high
            w = Pointer(UInt64).new(addr).value
            if @low <= w < @high && (i = find(w)) >= 0
              yield addr, i
            end
            addr += 8
          end
        end

        # Index of the target containing *w*, or -1
        private def find(w : UInt64) : Int32
          t = @targets.to_unsafe
          lo = 0
          hi = @targets.size - 1
          found = -1
          while lo <= hi
            mid = (lo + hi) >> 1
            if t[mid].start <= w
              found = mid
              lo = mid + 1
            else
              hi = mid - 1
            end
          end
          return -1 if found < 0
          w < t[found].stop ? found : -1
        end
      end

      # Collects the reachable objects of the given type IDs as targets
      private class TargetCollector < Visitor
        def initialize(@ids : Slice(Bool), @targets : RawBuffer(Target), @sizes : Slice(Int32))
        end

        def visit(obj : Void*, bytes : UInt64, scanned : Bool) : Nil
          id = Heap.type_id(obj, bytes, @sizes)
          return unless id > 0 && @ids.to_unsafe[id]
          base = obj.address
          @targets.push(Target.new(base, base + bytes, id))
        end
      end

      # Writable data segments of the executable and its libraries, where global and
      # class variables live
      def self.data_segments : Array({UInt64, UInt64})
        segments = [] of {UInt64, UInt64}
        {% if flag?(:linux) %}
          LibC.dl_iterate_phdr(->(info : LibC::DlPhdrInfo*, _size : LibC::SizeT, data : Void*) {
            list = data.as(Array({UInt64, UInt64}))
            info.value.phnum.times do |i|
              ph = info.value.phdr[i]
              next unless ph.type == 1 && ph.flags & 2 != 0 # PT_LOAD, PF_W
              low = info.value.addr + ph.vaddr
              list << {low.to_u64, (low + ph.memsz).to_u64}
            end
            0
          }, segments.as(Void*))
        {% end %}
        segments
      end

      record HolderReport, targets : Int32, truncated : Bool, holders : Array(Holder),
        target_list : Array(Target), fiber_names : Hash(UInt64, String?),
        collect : Time::Span, stopped : Time::Span

      MAX_TARGETS = 1 << 20
      MAX_HOLDERS = 1 << 20

      # Finds what references the reachable instances of the given type IDs
      def self.holders_of(type_ids : Array(Int32), max_holders = MAX_HOLDERS) : HolderReport
        ids = Slice(Bool).new(MAX_TYPE_ID, false)
        type_ids.each { |id| ids[id] = true if 0 < id < MAX_TYPE_ID }
        sizes = instance_sizes
        targets = RawBuffer(Target).new(MAX_TARGETS)
        holders = RawBuffer(Holder).new(max_holders)
        collector = TargetCollector.new(ids, targets, sizes)
        scanner = Scanner.new(targets, holders, data_segments, sizes)
        start = Time.instant
        GC.collect
        collect = Time.instant - start
        stopped = Debug.with_world_stopped do
          Debug.each_reachable_object(collector)
          scanner.scan
        end
        report(targets, holders, collect, stopped)
      end

      # Finds what references the given targets. The caller fills *targets* without
      # keeping the objects in GC visible memory, else it finds itself.
      def self.holders_of(targets : RawBuffer(Target), max_holders = MAX_HOLDERS) : HolderReport
        holders = RawBuffer(Holder).new(max_holders)
        scanner = Scanner.new(targets, holders, data_segments, instance_sizes)
        stopped = Debug.with_world_stopped { scanner.scan }
        report(targets, holders, Time::Span.zero, stopped)
      end

      private def self.report(targets, holders, collect, stopped) : HolderReport
        names = Hash(UInt64, String?).new
        Fiber.each { |f| names[f.object_id] = f.name }
        HolderReport.new(targets.size, holders.full?, holders.to_slice.to_a, targets.to_slice.to_a,
          names, collect, stopped)
      end
    end
  end
end
