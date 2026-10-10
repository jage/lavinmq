module LavinMQ
  module SortableJSON
    abstract def details_tuple

    def to_json(json : JSON::Builder)
      details_tuple.to_json(json)
    end

    protected def search_value
      @name
    end

    def search_match?(value : String)
      search_value.includes? value
    end

    def search_match?(value : Regex)
      value === search_value
    end

    def state_match?(_states : Array(QueueState)) : Bool
      true
    end

    # The value a list sorts on, *keys* being a column name split at dots: dug out of the
    # details unless the object has it cheaper
    def sort_value(keys : Array(String))
      SortableJSON.dig(details_tuple, keys)
    end

    def self.dig(tuple : NamedTuple, keys : Array(String))
      if keys.size > 1
        nt = tuple[keys.first].as?(NamedTuple) || raise KeyError.new("'#{keys.first}' is not a nested tuple")
        dig(nt, keys[1..])
      else
        tuple[keys.first]?
      end
    end
  end
end
