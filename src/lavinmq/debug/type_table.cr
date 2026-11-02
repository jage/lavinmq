module LavinMQ
  module Debug
    # Names and instance sizes of concrete reference types by type ID, built at compile time.
    #
    # Private types and generic instances with a private or non-type argument are left
    # out, as they can't be referenced from here.
    module TypeTable
      record Entry, name : String, instance_size : Int32

      class_getter entries : Hash(Int32, Entry) { build }

      def self.[]?(id : Int32) : Entry?
        entries[id]?
      end

      def self.name(id : Int32) : String?
        entries[id]?.try &.name
      end

      # Type IDs whose name is *name*, or starts with "*name*(" for generic instances
      def self.ids_for(name : String) : Array(Int32)
        prefix = "#{name}("
        entries.compact_map { |id, e| id if e.name == name || e.name.starts_with?(prefix) }
      end

      # How much bigger than the instance size a GC object of the type can be. Small
      # sizes get an extra byte (so pointers just past the end are interior) and are
      # rounded up to granules (16 B) and size classes (up to 1/8 more); large objects
      # (over 2 KiB) are rounded up to blocks (4 KiB).
      @[AlwaysInline]
      def self.slack(instance_size : UInt64) : UInt64
        instance_size > 2048 ? 4096_u64 : Math.max(16_u64, instance_size // 4)
      end

      private def self.build : Hash(Int32, Entry)
        entries = Hash(Int32, Entry).new
        LavinMQDebugTypes.all.each { |id, name, size| entries[id] = Entry.new(name, size) }
        entries
      end
    end
  end
end

# Top level, so the type names in the macro resolve from the top level namespace and not
# from LavinMQ's (where Log is LavinMQ::Log)
private module LavinMQDebugTypes
  def self.all : Array({Int32, String, Int32})
    {% begin %}
    [
        {% for t in Reference.all_subclasses %}
          {% hidden = t.abstract? %}
          {% work = [t] %}
          {% for i in 0...64 %}
            {% if !hidden && i < work.size %}
              {% w = work[i] %}
              {% if w.union? %}
                {% for u in w.union_types %}{% work << u %}{% end %}
              {% elsif w.is_a?(TypeNode) %}
                {% parts = w.name(generic_args: false).stringify.split("(")[0].split("::") %}
                {% for j in 0...parts.size %}
                  {% unless hidden %}
                    {% p = parse_type(parts[0..j].join("::")).resolve? %}
                    {% hidden = true if p.nil? || (p.is_a?(TypeNode) && p.private?) %}
                  {% end %}
                {% end %}
                {% for v in w.type_vars %}
                  {% if v.is_a?(TypeNode) %}{% work << v %}{% else %}{% hidden = true unless v.is_a?(NumberLiteral) %}{% end %}
                {% end %}
              {% else %}
                {% hidden = true %}
              {% end %}
            {% end %}
          {% end %}
          {% hidden = true if work.size > 64 %}
          {% unless hidden %}
            { {{ t }}.crystal_instance_type_id, {{ t.stringify }}, instance_sizeof({{ t }}).to_i32 },
          {% end %}
        {% end %}
    ] of {Int32, String, Int32}
    {% end %}
  end
end
