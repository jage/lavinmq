require "socket"
require "./heap"

module LavinMQ
  module Debug
    # Tracks finished fibers and closed sockets with weak references, to tell how many the
    # GC still finds reachable, and what holds them. Off by default; when off the hooks
    # cost one load and branch per finished fiber and closed socket.
    module Retention
      MAX_TRACKED = 500_000

      # A weak reference in memory the GC doesn't scan, cleared when the target is
      # collected
      class WeakLink
        @target : Void*

        def self.allocate
          ptr = GC.malloc_atomic(instance_sizeof(self)).as(self)
          set_crystal_type_id(ptr)
          ptr
        end

        def initialize(target : Void*)
          @target = target
          GC.register_disappearing_link(pointerof(@target)) if GC.is_heap_ptr(target)
        end

        # The target's address, or 0 once collected. Not a reference: keep it out of GC
        # scanned memory, or it keeps the target alive.
        def address : UInt64
          @target.address
        end
      end

      enum Kind
        Fiber
        Socket
      end

      class Entry
        getter kind : Kind
        getter name : String
        getter target : WeakLink
        # The fiber's stack (lowest address); fibers spawned later reuse it
        getter stack : UInt64
        getter at : Time::Instant
        property next : Entry?

        def initialize(@kind, @name, @target, @stack, @at)
        end
      end

      @@enabled = false
      @@tracked = Atomic(Int32).new(0)
      @@dropped = Atomic(Int64).new(0)
      @@total = Atomic(Int64).new(0)
      @@head = Atomic(Entry?).new(nil)
      @@enabled_at : Time::Instant? = nil

      def self.enabled? : Bool
        @@enabled
      end

      def self.enable : Nil
        @@enabled_at ||= Time.instant
        @@enabled = true
      end

      # Stops tracking and forgets everything tracked
      def self.disable : Nil
        @@enabled = false
        @@enabled_at = nil
        @@head.swap(nil)
        @@tracked.set(0)
        @@dropped.set(0)
        @@total.set(0)
      end

      def self.fiber_finished(fiber : ::Fiber) : Nil
        track(Kind::Fiber, fiber.name || "", fiber.as(Void*), fiber.@stack.pointer.address)
      end

      def self.socket_closed(socket : ::Socket) : Nil
        track(Kind::Socket, socket.class.name, socket.as(Void*), 0_u64)
      end

      private def self.track(kind, name, target : Void*, stack : UInt64) : Nil
        @@total.add(1, :relaxed)
        if @@tracked.add(1, :relaxed) >= MAX_TRACKED
          @@tracked.sub(1, :relaxed)
          @@dropped.add(1, :relaxed)
          return
        end
        entry = Entry.new(kind, name, WeakLink.new(target), stack, Time.instant)
        push(entry)
      end

      private def self.push(entry : Entry) : Nil
        head = @@head.get(:acquire)
        loop do
          entry.next = head
          head, ok = @@head.compare_and_set(head, entry, :acquire_release, :acquire)
          break if ok
        end
      end

      record Retained, kind : Kind, name : String, stack : UInt64, age : Time::Span

      record Report, enabled : Bool, enabled_for : Time::Span?, total : Int64, dropped : Int64,
        tracked : Int32, retained : Array(Retained), collect : Time::Span,
        holders : Heap::HolderReport?

      # Collects, forgets the entries whose targets were collected, and reports the rest.
      # With *holders*, also scans the heap, fiber stacks and data segments (stopping the
      # world) for what references the retained fibers and sockets.
      def self.report(holders = false) : Report
        start = Time.instant
        GC.collect
        collect = Time.instant - start
        now = Time.instant
        retained = [] of Retained
        survivors = [] of Entry
        # Entries pushed meanwhile stay in the list and are reported next time
        entry = @@head.swap(nil)
        while node = entry
          entry = node.next
          if node.target.address == 0
            @@tracked.sub(1, :relaxed)
          else
            survivors << node
          end
        end
        survivors.each do |e|
          push(e)
          retained << Retained.new(e.kind, e.name, e.stack, now - e.at)
        end
        holder_report = nil
        if holders && !survivors.empty?
          # Tags are indexes in the retained list. Written straight from the weak links,
          # so no GC visible memory references the targets during the scan.
          targets = RawBuffer(Heap::Target).new(survivors.size)
          survivors.each_with_index do |e, i|
            addr = e.target.address
            next if addr == 0
            size = LibGC.size(Pointer(Void).new(addr)).to_u64
            targets.push(Heap::Target.new(addr, addr + size, i))
          end
          holder_report = Heap.holders_of(targets)
        end
        Report.new(@@enabled, @@enabled_at.try { |t| now - t }, @@total.get, @@dropped.get,
          @@tracked.get, retained, collect, holder_report)
      end
    end
  end
end

class Fiber
  # :nodoc:
  def self.inactive(fiber : Fiber)
    previous_def
    LavinMQ::Debug::Retention.fiber_finished(fiber) if LavinMQ::Debug::Retention.enabled?
  end
end

class Socket
  private def unbuffered_close : Nil
    LavinMQ::Debug::Retention.socket_closed(self) if !@closed && LavinMQ::Debug::Retention.enabled?
    previous_def
  end
end
