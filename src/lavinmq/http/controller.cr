require "./router"
require "../sortable_json"

module LavinMQ
  module HTTP
    abstract class Controller
      include Router

      # Define Log in each controller
      # source will be "lmq.http.<controller name>" without controller suffix
      macro inherited
        Log = LavinMQ::Log.for "http.{{ @type.name.split("::").last.downcase.gsub(/controller$/, "").id }}"
      end

      def initialize(@server : LavinMQ::Server)
        register_routes
      end

      private abstract def register_routes

      # Filters and sorts the items themselves and only builds details for the returned page,
      # so a page of 100 out of 100k items doesn't materialize 100k detail tuples.
      private def page(context, items : Array(SortableJSON))
        params = context.request.query_params
        page_size = extract_page_size(context)
        search_term = extract_search_term(params)
        states = extract_state_filter(context)
        total_count = items.size
        matching = items.select do |i|
          (search_term.nil? || i.search_match?(search_term)) && (states.nil? || i.state_match?(states))
        rescue ex
          Log.warn(exception: ex) { "Could not list all items" }
          false
        end
        matching = sort(matching, context)
        columns = params["columns"]?.try(&.split(','))
        if page = params["page"]?.try(&.to_i)
          # Built before writing: writing the response can yield, and the page should be one snapshot
          tuples = details_tuples(matching, (page - 1) * page_size, page_size)
          JSON.build(context.response) do |json|
            json.object do
              json.field("items") { items_to_json(json, tuples, columns) }
              json.field("filtered_count", matching.size)
              json.field("item_count", tuples.size)
              json.field("page", page)
              json.field("page_count", ((matching.size + page_size - 1) / page_size).to_i)
              json.field("page_size", page_size)
              json.field("total_count", total_count)
            end
          end
        else
          tuples = details_tuples(matching, 0, MAX_PAGE_SIZE)
          if matching.size > MAX_PAGE_SIZE
            Log.warn { "Result set truncated: #{tuples.size}/#{matching.size}" }
          end
          JSON.build(context.response) { |json| items_to_json(json, tuples, columns) }
        end
        context
      end

      # Details of the items in [start, start + count), skipping any that fail
      private def details_tuples(items, start : Int, count : Int)
        from = start.clamp(0, items.size)
        to = (start + count).clamp(from, items.size)
        items[from...to].compact_map { |i| details_tuple?(i) }
      end

      private def details_tuple?(item)
        item.details_tuple
      rescue ex
        Log.warn(exception: ex) { "Could not list all items" }
        nil
      end

      private def sort(items, context)
        if sort_by = context.request.query_params.fetch("sort", nil).try &.split(".")
          begin
            items = sort_by_key(items, sort_by, context)
          rescue KeyError | TypeCastError
            bad_request(context, "Sort key #{sort_by.join(".")} is not valid")
          end
          if context.request.query_params["sort_reverse"]?.try { |s| !(s =~ /^false$/i) }
            items.reverse!
          end
        end
        items
      end

      private def sort_by_key(items, sort_by, context)
        # Find first non-nil value to determine the sort type
        sample_value = items.each do |item|
          next unless value = sort_value?(item, sort_by)
          break value[0] unless value[0].nil?
        end
        case sample_value
        when Number
          sort_by_value(items, sort_by) { |v| v.as?(Number) || 0 }
        when String
          sort_by_value(items, sort_by) { |v| lowercase(v.as?(String) || "") }
        when Bool
          sort_by_value(items, sort_by) { |v| v.as?(Bool) ? 1 : 0 }
        when QueueState
          sort_by_value(items, sort_by) { |v| v.as?(QueueState) || QueueState::Closed }
        when Nil
          items # all values are nil, nothing to sort
        else
          bad_request(context, "Can't sort on type #{sample_value.class}")
        end
      end

      # Sorts the items on one key per item, dropping items whose details fail. The original
      # position breaks ties, so the order is that of a stable sort with fewer bytes moved.
      private def sort_by_value(items, sort_by, &)
        i = -1
        keyed = items.compact_map do |item|
          i += 1
          next unless value = sort_value?(item, sort_by)
          {yield(value[0]), i}
        end
        keyed.unstable_sort! do |a, b|
          c = a[0] <=> b[0] || raise ArgumentError.new("Comparison of #{a[0]} and #{b[0]} failed")
          c == 0 ? a[1] <=> b[1] : c
        end
        keyed.map { |(_, index)| items[index] }
      end

      # The item's value at `keys`, wrapped so a nil value differs from an item whose details fail
      private def sort_value?(item, keys)
        value = begin
          item.details_value(keys.first)
        rescue ex
          Log.warn(exception: ex) { "Could not list all items" }
          return
        end
        return {value} if keys.size == 1
        nt = value.as?(NamedTuple) || raise KeyError.new("'#{keys.first}' is not a nested tuple")
        {dig(nt, keys[1..])}
      end

      # Same as String#downcase, without allocating when there is nothing to lowercase
      private def lowercase(s : String) : String
        s.ascii_only? && s.to_slice.none?(&.unsafe_chr.ascii_uppercase?) ? s : s.downcase
      end

      private def dig(tuple : NamedTuple, keys : Array(String))
        if keys.size > 1
          nt = tuple[keys.first].as?(NamedTuple) || raise KeyError.new("'#{keys.first}' is not a nested tuple")
          dig(nt, keys[1..])
        else
          tuple[keys.first]?
        end
      end

      private def items_to_json(json, tuples, columns : Array(String)?) : Nil
        json.array do
          tuples.each do |o|
            if columns
              json.object do
                columns.each do |col|
                  json.field col, o[col]
                rescue KeyError
                  next
                end
              end
            else
              o.to_json(json)
            end
          end
        end
      end

      private def extract_page_size(context) : Int32
        page_size = context.request.query_params["page_size"]?.try(&.to_i) || 100
        if page_size > MAX_PAGE_SIZE
          halt(context, 413, {error: "payload_too_large", reason: "Max allowed page_size #{MAX_PAGE_SIZE}"})
        end
        page_size
      end

      private def extract_search_term(params)
        if term = params["name"]?
          if params["use_regex"]? == "true"
            Regex.new(term)
          else
            term
          end
        end
      end

      private def extract_state_filter(context) : Array(QueueState)?
        return unless param = context.request.query_params["state"]?
        param.split(',').map do |s|
          QueueState.parse?(s) || bad_request(context, "Invalid queue state '#{s}'")
        end
      end

      private def redirect_back(context)
        context.response.headers["Location"] = context.request.headers["Referer"]
        halt(context, 302)
      end

      private def parse_body(context) : JSON::Any
        if context.request.content_length == 0
          return JSON::Any.new(Hash(String, JSON::Any).new)
        end
        if body = context.request.body
          ct = context.request.headers["Content-Type"]?
          if ct.nil? || ct.empty? || ct == "application/json"
            json = JSON.parse(body)
            if json.as_h?
              json
            else
              bad_request(context, "Request body has to be a JSON object")
            end
          else
            unsupported_content_type(context, ct)
          end
        else
          bad_request(context, "Request body required")
        end
      rescue JSON::ParseException
        bad_request(context, "Malformed JSON")
      end

      private def not_found(context, message = "Not Found")
        halt(context, 404, {error: "Object Not Found", reason: message})
      end

      private def bad_request(context, message)
        halt(context, 400, {error: "bad_request", reason: message})
      end

      private def access_refused(context, message = "Access refused")
        halt(context, 403, {error: "access_refused", reason: message})
      end

      private def forbidden(context, message = "Forbidden")
        halt(context, 403, {error: "forbidden", reason: message})
      end

      private def precondition_failed(context, message = "Precondition failed")
        halt(context, 412, {error: "precondition_failed", reason: message})
      end

      private def unsupported_content_type(context, content_type)
        halt(context, 415, {error: "unsupported_content_type", reason: "Unsupported content type #{content_type}"})
      end

      private def halt(context, status_code, body = nil)
        context.response.status_code = status_code
        body.try &.to_json(context.response)
        raise HaltRequest.new(body.try { |b| b[:reason] })
      end

      private def with_vhost(context, params, *, vhost_key = "vhost", &)
        name = params[vhost_key]?
        if name && (vhost = @server.vhosts[name]?)
          refuse_unless_vhost_access(context, user(context), vhost)
          yield vhost
        elsif user(context).tags.any? &.administrator?
          not_found(context, "Vhost #{name} does not exist")
        else
          access_refused(context)
        end
        context
      end

      private def user(context) : Auth::BaseUser
        unless user = context.user # Should it be possible to end up here with nil user?
          Log.warn { "No authorized user for request path=#{context.request.path}" }
          access_refused(context)
        end
        user
      end

      def vhosts(user : Auth::BaseUser) : Array(VHost)
        @server.vhosts.values.select do |v|
          full_view_vhosts_access = user.tags.any? { |t| t.administrator? || t.monitoring? }
          amqp_access = user.permissions.has_key?(v.name)
          full_view_vhosts_access || (amqp_access && !user.tags.empty?)
        end
      end

      private def refuse_unless_vhost_access(context, user, vhost : VHost)
        return if user.tags.any? &.administrator?
        unless user.permissions.has_key?(vhost.name)
          Log.warn { "user=#{user.name} does not have permissions to access vhost=#{vhost.name}" }
          access_refused(context)
        end
      end

      private def refuse_unless_management(context, user, vhost : VHost? = nil)
        unless user.tags.any? do |t|
                 t.administrator? || t.monitoring? || t.policy_maker? || t.management?
               end
          Log.warn { "user=#{user.name} does not have management access on vhost=#{vhost.try(&.name)}" }
          access_refused(context)
        end
      end

      private def refuse_unless_policymaker(context, user, vhost : VHost? = nil)
        unless user.tags.any? { |t| t.policy_maker? || t.administrator? }
          Log.warn { "user=#{user.name} does not have policymaker access on vhost=#{vhost.try(&.name)}" }
          access_refused(context)
        end
      end

      private def refuse_unless_administrator(context, user : Auth::BaseUser)
        unless user.tags.any? &.administrator?
          Log.warn { "user=#{user.name} does not have administrator access" }
          access_refused(context)
        end
      end

      class HaltRequest < Exception; end
    end
  end
end
