module LavinMQ
  module SortableJSON
    abstract def details_tuple

    def to_json(json : JSON::Builder)
      details_tuple.to_json(json)
    end

    # One field of details_tuple. Types listed in large numbers override this so sorting
    # on common fields doesn't build the whole tuple for every item.
    def details_value(key : String)
      details_tuple[key]?
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
  end
end
