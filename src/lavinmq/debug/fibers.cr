require "json"
require "./unwind"

module LavinMQ
  module Debug
    # A snapshot of every fiber, without stopping the world. The fiber list's lock is held
    # while it's read, which blocks spawning and finishing fibers for that time (about
    # 3 us per fiber with backtraces).
    module Fibers
      enum State
        Running  # currently executing on a thread
        Runnable # suspended and queued to run
        Parked   # suspended, waiting for an event
      end

      record Info, name : String?, state : State, execution_context : String?,
        stack_size : Int32, stack_used : UInt64?, ips : Array(Void*)?

      record Snapshot, fibers : Array(Info), sampled : Time::Span, symbolized : Time::Span,
        frames : Hash(Void*, String)

      def self.snapshot(backtraces = true, filter : String? = nil) : Snapshot
        start = Time.instant
        runnable = runnable_fibers
        infos = Array(Info).new(Fiber.count)
        cache = Unwind::Cache.new
        Fiber.each do |f|
          name = f.name
          next if filter && !name.try(&.includes?(filter))
          state = if f.running?
                    State::Running
                  elsif runnable.includes?(f.object_id)
                    State::Runnable
                  else
                    State::Parked
                  end
          ips = Unwind.backtrace(f, cache) if backtraces && !state.running?
          infos << Info.new(name, state, f.execution_context?.try(&.name), f.@stack.size, f.stack_used, ips)
        end
        sampled = Time.instant - start
        frames = Hash(Void*, String).new
        if backtraces
          Exception::CallStack.load_debug_info
          infos.each do |i|
            i.ips.try &.each do |ip|
              frames[ip] ||= Exception::CallStack.decode_backtrace_frame(ip, false) || "0x#{ip.address.to_s(16)}"
            end
          end
        end
        Snapshot.new(infos, sampled, Time.instant - start - sampled, frames)
      end

      # Object IDs of the fibers queued to run, read from the schedulers' queues. Best
      # effort: the queues are read without stopping their threads.
      def self.runnable_fibers : Set(UInt64)
        set = Set(UInt64).new
        Fiber::ExecutionContext.each do |ec|
          case ec
          when Fiber::ExecutionContext::Parallel
            gq = ec.@global_queue
            gq.@mutex.synchronize { gq.@list.each { |f| set << f.object_id } }
            ec.@schedulers.each do |s|
              runnables = s.@runnables
              head = runnables.@head.get(:acquire)
              tail = runnables.@tail.get(:acquire)
              buffer = runnables.@buffer.to_unsafe
              n = runnables.@buffer.size.to_u32
              count = Math.min(tail &- head, n)
              count.times { |i| set << buffer[(head &+ i) % n].object_id }
            end
          when Fiber::ExecutionContext::Isolated
            set << ec.@main_fiber.object_id if ec.@enqueued
          end
        end
        set
      end

      def self.to_json(json : JSON::Builder, snap : Snapshot, list_limit : Int32) : Nil
        fibers = snap.fibers
        json.object do
          json.field "total", fibers.size
          json.field "states" do
            json.object do
              State.each { |s| json.field s.to_s.downcase, fibers.count(&.state.==(s)) }
            end
          end
          json.field "stack_used_bytes", fibers.sum { |f| f.stack_used || 0_u64 }
          json.field "sample_ms", snap.sampled.total_milliseconds.round(3)
          json.field "symbolize_ms", snap.symbolized.total_milliseconds.round(3)
          json.field "by_name" do
            groups_to_json(json, fibers.group_by { |f| f.name || "" })
          end
          # Names often carry a queue, vhost or client name; the first word groups those
          json.field "by_name_prefix" do
            groups_to_json(json, fibers.group_by { |f| (f.name || "").split(' ', 2).first })
          end
          json.field "fibers" do
            json.array do
              fibers.first(list_limit).each do |f|
                json.object do
                  json.field "name", f.name
                  json.field "state", f.state.to_s.downcase
                  json.field "execution_context", f.execution_context
                  json.field "stack_size", f.stack_size
                  json.field "stack_used", f.stack_used
                  if ips = f.ips
                    json.field "backtrace" do
                      json.array { ips.each { |ip| json.string snap.frames[ip] } }
                    end
                  end
                end
              end
            end
          end
        end
      end

      private def self.groups_to_json(json, groups : Hash(String, Array(Info))) : Nil
        json.array do
          groups.to_a.sort_by! { |_, v| -v.size }.each do |name, list|
            json.object do
              json.field "name", name
              json.field "count", list.size
              State.each do |s|
                n = list.count(&.state.==(s))
                json.field s.to_s.downcase, n if n > 0
              end
              json.field "stack_used_bytes", list.sum { |f| f.stack_used || 0_u64 }
            end
          end
        end
      end
    end
  end
end
