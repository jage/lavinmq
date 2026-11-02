require "json"
require "./heap"
require "./retention"

module LavinMQ
  module Debug
    # JSON output of the introspection reports
    module Report
      def self.ms(span : Time::Span) : Float64
        span.total_milliseconds.round(3)
      end

      def self.gc_stats(json : JSON::Builder) : Nil
        ps = GC.prof_stats
        json.object do
          json.field "gc_no", ps.gc_no
          json.field "heap_size", ps.heap_size
          json.field "free_bytes", ps.free_bytes
          json.field "unmapped_bytes", ps.unmapped_bytes
          json.field "bytes_since_gc", ps.bytes_since_gc
          json.field "markers", ps.markers_m1 + 1
        end
      end

      def self.census(json : JSON::Builder, c : Heap::Census, limit : Int32) : Nil
        json.object do
          json.field "gc" { gc_stats(json) }
          json.field "collect_ms", ms(c.collect)
          json.field "stop_the_world_ms", ms(c.stopped)
          json.field "objects", c.objects
          json.field "bytes", c.bytes
          json.field "scanned_bytes", c.scanned_bytes
          json.field "pointer_free_bytes", c.bytes - c.scanned_bytes
          json.field "types" do
            json.array do
              c.rows.first(limit).each do |r|
                json.object do
                  json.field "type", r.name
                  json.field "scanned", r.scanned
                  json.field "count", r.count
                  json.field "bytes", r.bytes
                end
              end
            end
          end
        end
      end

      # Words pointing into targets, grouped by where they are: a fiber's stack (by fiber
      # name, up to its first space, and offset from the stack bottom), a heap object (by
      # type, with the most common offsets in it) or a data segment (by symbol).
      #
      # *same_stack* tells if a stack word is on the stack its target last ran on.
      def self.holders(json : JSON::Builder, r : Heap::HolderReport, limit : Int32,
                       include_target : Proc(Int32, Bool)? = nil,
                       same_stack : Proc(Heap::Holder, Bool)? = nil) : Nil
        targets = r.target_list
        groups = Hash({Heap::HolderKind, String, Int64, Bool}, Group).new
        held = Set(Int32).new
        total = targets.count { |t| include_target.nil? || include_target.call(t.tag) }
        r.holders.each do |h|
          t = targets[h.target]
          next if include_target && !include_target.call(t.tag)
          held << h.target
          group = groups[group_key(r, h, t)] ||= Group.new
          group.targets << h.target
          group.words += 1
          group.offsets[h.offset] += 1 if h.kind.heap?
          group.same_stack += 1 if same_stack && h.kind.stack? && same_stack.call(h)
        end
        json.object do
          json.field "stop_the_world_ms", ms(r.stopped)
          json.field "targets", total
          json.field "unattributed", total - held.size
          json.field "truncated", r.truncated
          json.field "groups" do
            json.array do
              groups.to_a.sort_by! { |_, g| -g.targets.size }.first(limit).each do |key, g|
                group_to_json(json, key, g, !same_stack.nil?)
              end
            end
          end
        end
      end

      # Stack words by fiber name prefix and offset, heap words by holder type, static
      # words by symbol
      private def self.group_key(r, h : Heap::Holder, t : Heap::Target) : {Heap::HolderKind, String, Int64, Bool}
        case h.kind
        in .stack?
          name = r.fiber_names.fetch(h.holder) { "<finished fiber>" }.try(&.split(' ', 2).first) || "<unnamed fiber>"
          {h.kind, name, h.offset, t.start == h.holder} # the last: a fiber's reference to itself
        in .heap?   then {h.kind, Heap.holder_name(h.holder_type), -1_i64, false}
        in .static? then {h.kind, static_name(h.holder), -1_i64, false}
        end
      end

      private def self.group_to_json(json, key, g : Group, same_stack : Bool) : Nil
        kind, name, offset, own = key
        json.object do
          json.field "kind", kind.to_s.downcase
          json.field "holder", name
          json.field "offset", offset if kind.stack?
          json.field "own_stack", true if own
          json.field "targets", g.targets.size
          json.field "words", g.words
          json.field "same_stack", g.same_stack if same_stack && kind.stack?
          if kind.heap?
            json.field "offsets" do
              json.object do
                g.offsets.to_a.sort_by! { |_, n| -n }.first(5).each { |o, n| json.field o.to_s, n }
              end
            end
            json.field "distinct_offsets", g.offsets.size
          end
        end
      end

      private class Group
        getter targets = Set(Int32).new
        getter offsets = Hash(Int64, Int32).new(0)
        property words = 0
        property same_stack = 0
      end

      private def self.static_name(addr : UInt64) : String
        {% if flag?(:unix) %}
          if LibC.dladdr(Pointer(Void).new(addr), out info) != 0
            if !info.dli_sname.null?
              return "#{String.new(info.dli_sname)}+#{addr - info.dli_saddr.address}"
            elsif !info.dli_fname.null?
              return "<data of #{File.basename(String.new(info.dli_fname))}>"
            end
          end
        {% end %}
        "<data>"
      end

      AGES = {1.second, 10.seconds, 60.seconds, 600.seconds}

      def self.retention(json : JSON::Builder, r : Retention::Report, limit : Int32) : Nil
        json.object do
          json.field "enabled", r.enabled
          json.field "enabled_seconds", r.enabled_for.try(&.total_seconds.round(1))
          json.field "tracked_total", r.total
          json.field "tracked_now", r.tracked
          json.field "dropped", r.dropped
          json.field "collect_ms", ms(r.collect)
          Retention::Kind.each do |kind|
            list = r.retained.select(&.kind.==(kind))
            json.field kind.fiber? ? "fibers" : "sockets" do
              json.object do
                json.field "retained", list.size
                json.field "oldest_seconds", list.max_of?(&.age.total_seconds.round(1))
                json.field "by_age" do
                  json.object do
                    lower = Time::Span.zero
                    AGES.each do |upper|
                      json.field "#{lower.total_seconds.to_i}-#{upper.total_seconds.to_i}s", list.count { |e| lower <= e.age < upper }
                      lower = upper
                    end
                    json.field ">#{lower.total_seconds.to_i}s", list.count { |e| e.age >= lower }
                  end
                end
                json.field kind.fiber? ? "by_name" : "by_type" do
                  json.array do
                    list.group_by { |e| kind.fiber? ? e.name.split(' ', 2).first : e.name }
                      .to_a.sort_by! { |_, v| -v.size }.first(limit).each do |name, v|
                      json.object do
                        json.field "name", name
                        json.field "count", v.size
                      end
                    end
                  end
                end
                if h = r.holders
                  retained = r.retained
                  json.field "holders" do
                    holders(json, h, limit,
                      include_target: ->(tag : Int32) { retained[tag].kind == kind },
                      same_stack: ->(holder : Heap::Holder) { holder.holder_stack == retained[h.target_list[holder.target].tag].stack })
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end
