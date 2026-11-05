# Maps the type IDs of public, concrete reference types to their names, built at compile time
module TypeTable
  def self.names : Hash(Int32, String)
    {% begin %}
    {
    {% for t in Reference.all_subclasses %}
      {% hidden = t.abstract? %}
      {% work = [t] %}
      {% for i in 0...400 %}
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
      {% unless hidden %}
        {{t}}.crystal_instance_type_id => {{t.stringify}},
      {% end %}
    {% end %}
    } of Int32 => String
    {% end %}
  end
end
