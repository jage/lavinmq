require "../controller"
require "../../debug/fibers"
require "../../debug/report"

module LavinMQ
  module HTTP
    # Runtime introspection of the current node: fibers, live heap and retention of
    # finished fibers and closed sockets. Administrator only, one request at a time.
    # `heap`, `holders` and `retention` force a collection and stop the world; see
    # docs/debugging.md.
    class DebugController < Controller
      @busy = Atomic(Bool).new(false)

      private def register_routes
        get "/api/debug/fibers" do |context, _params|
          exclusive(context) do
            params = context.request.query_params
            snap = Debug::Fibers.snapshot(backtraces: params["backtrace"]? != "false", filter: params["name"]?)
            JSON.build(context.response.output) do |json|
              Debug::Fibers.to_json(json, snap, int_param(context, "limit", 1000))
            end
          end
        end

        get "/api/debug/heap" do |context, _params|
          exclusive(context) do
            census = Debug::Heap.census
            JSON.build(context.response.output) do |json|
              Debug::Report.census(json, census, int_param(context, "limit", 50))
            end
          end
        end

        get "/api/debug/holders" do |context, _params|
          exclusive(context) do
            type = context.request.query_params["type"]? || bad_request(context, "Query parameter 'type' is required")
            ids = Debug::TypeTable.ids_for(type)
            bad_request(context, "Unknown type '#{type}'") if ids.empty?
            report = Debug::Heap.holders_of(ids)
            JSON.build(context.response.output) do |json|
              json.object do
                json.field "type", type
                json.field "types" do
                  json.array { ids.each { |id| json.string Debug::TypeTable.name(id) } }
                end
                json.field "collect_ms", Debug::Report.ms(report.collect)
                json.field "holders" do
                  Debug::Report.holders(json, report, int_param(context, "limit", 50))
                end
              end
            end
          end
        end

        get "/api/debug/retention" do |context, _params|
          exclusive(context) do
            holders = context.request.query_params["holders"]? == "true"
            report = Debug::Retention.report(holders: holders)
            JSON.build(context.response.output) do |json|
              Debug::Report.retention(json, report, int_param(context, "limit", 20))
            end
          end
        end

        put "/api/debug/retention" do |context, _params|
          refuse_unless_administrator(context, user(context))
          enabled = parse_body(context)["enabled"]?.try(&.as_bool?)
          bad_request(context, "Field 'enabled' (boolean) is required") if enabled.nil?
          if enabled
            Debug::Retention.enable
          else
            Debug::Retention.disable
          end
          Log.info { "Retention tracking #{enabled ? "enabled" : "disabled"}" }
          {enabled: enabled}.to_json(context.response.output)
          context
        end
      end

      private def exclusive(context, &)
        refuse_unless_administrator(context, user(context))
        unless @busy.compare_and_set(false, true)[1]
          halt(context, 429, {error: "busy", reason: "Another debug request is running"})
        end
        begin
          yield
        ensure
          @busy.set(false)
        end
        context
      end

      private def int_param(context, name, default : Int32) : Int32
        value = context.request.query_params[name]? || return default
        int = value.to_i?
        bad_request(context, "Query parameter '#{name}' must be a non-negative integer") if int.nil? || int < 0
        int
      end
    end
  end
end
