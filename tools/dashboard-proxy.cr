require "http/server"
require "http/client"
require "option_parser"
require "uri"
require "base64"
require "log"

# Read-only local dashboard proxy.
#
# Serves the in-repo `static/` assets and reverse-proxies `/api/*` and `/metrics`
# to a remote LavinMQ. Blocks every non-GET/HEAD method so the session can't
# mutate remote state. Intended for iterating on the dashboard UI against
# real servers without risk.
#
# Usage:
#   make views && make js                     # once, to populate static/
#   crystal run tools/dashboard-proxy.cr -- [--bind HOST:PORT] <URL>
#
# Example:
#   crystal run tools/dashboard-proxy.cr -- http://guest:guest@127.0.0.1:15672
module DashboardProxy
  STATIC_DIR = File.expand_path("../static", __DIR__)

  ALLOWED_METHODS      = {"GET", "HEAD"}
  PROXY_PREFIXES       = {"/api/", "/metrics"}
  FORWARD_REQ_HEADERS  = {"Accept", "If-None-Match", "If-Modified-Since"}
  FORWARD_RESP_HEADERS = {"Content-Type", "ETag", "Last-Modified", "Cache-Control"}

  Log = ::Log.for("dashboard-proxy")

  def self.run(argv)
    bind = "127.0.0.1:15673"
    positional = [] of String

    parser = OptionParser.new do |p|
      p.banner = "Usage: crystal run tools/dashboard-proxy.cr -- [options] <target-url>"
      p.on("-b HOST:PORT", "--bind=HOST:PORT", "Local bind address (default 127.0.0.1:15673)") { |v| bind = v }
      p.on("-h", "--help", "Show help") { puts p; exit 0 }
      p.unknown_args { |args| positional = args }
    end
    parser.parse(argv)

    target_raw = positional.first? || abort(parser.to_s)
    upstream = parse_upstream(target_raw)
    auth = "Basic #{Base64.strict_encode("#{upstream.user}:#{upstream.password}")}"

    safe = URI.new(scheme: upstream.scheme, host: upstream.host, port: upstream.port)
    Log.info { "serving dashboard on http://#{bind} -> #{safe} (read-only)" }
    Log.info { "static dir: #{STATIC_DIR}" } unless Dir.exists?(STATIC_DIR)

    host, port = split_bind(bind)
    server = HTTP::Server.new do |context|
      handle(context, upstream, auth)
    end
    server.bind_tcp(host, port)
    server.listen
  end

  private def self.parse_upstream(raw)
    uri = URI.parse(raw)
    abort "target URL must include scheme and host: #{raw}" unless uri.scheme && uri.host
    abort "target URL must include user:password" unless uri.user && uri.password
    uri
  end

  private def self.split_bind(bind)
    colon = bind.rindex(':') || abort "bad bind: #{bind}"
    {bind[0...colon], bind[(colon + 1)..].to_i}
  end

  def self.handle(context, upstream, auth)
    req = context.request
    path = req.path

    unless ALLOWED_METHODS.includes?(req.method)
      Log.warn { "blocked #{req.method} #{req.resource}" }
      context.response.status = HTTP::Status::METHOD_NOT_ALLOWED
      context.response.headers["Allow"] = "GET, HEAD"
      context.response.content_type = "application/json"
      context.response.print %({"error":"read-only proxy"})
      return
    end

    if PROXY_PREFIXES.any? { |prefix| path == prefix.rstrip('/') || path.starts_with?(prefix) }
      proxy(context, upstream, auth)
    else
      serve_static(context)
    end
  end

  def self.proxy(context, upstream, auth)
    req = context.request
    headers = HTTP::Headers.new
    FORWARD_REQ_HEADERS.each do |h|
      if v = req.headers[h]?
        headers[h] = v
      end
    end
    headers["Authorization"] = auth

    streaming = false
    HTTP::Client.new(upstream) do |client|
      client.connect_timeout = 5.seconds
      client.compress = false
      client.exec(req.method, req.resource, headers) do |upstream_resp|
        context.response.status_code = upstream_resp.status_code
        FORWARD_RESP_HEADERS.each do |h|
          if v = upstream_resp.headers[h]?
            context.response.headers[h] = v
          end
        end
        if body_io = upstream_resp.body_io?
          streaming = true
          IO.copy(body_io, context.response)
        end
      end
    end
  rescue ex : IO::Error | Socket::Error
    Log.error { "upstream error for #{context.request.resource}: #{ex.message}" }
    return if streaming
    context.response.status = HTTP::Status::BAD_GATEWAY
    context.response.content_type = "application/json"
    context.response.print %({"error":"upstream error"})
  end

  def self.serve_static(context)
    req = context.request
    resolved = resolve_static(req.path)
    unless resolved
      context.response.status = HTTP::Status::NOT_FOUND
      return
    end
    File.open(resolved) do |file|
      context.response.content_type = mime_type(resolved)
      context.response.headers["Cache-Control"] = "no-cache"
      context.response.content_length = file.size
      IO.copy(file, context.response) if req.method == "GET"
    end
  end

  private def self.resolve_static(path)
    return nil if path.includes?("..")
    path = "/overview" if path == "/"
    path = "/docs/index.html" if path == "/docs/"
    full = File.join(STATIC_DIR, path)
    return full if File.file?(full)
    html = "#{full}.html"
    return html if File.file?(html)
    nil
  end

  # ameba:disable Metrics/CyclomaticComplexity
  private def self.mime_type(path)
    case File.extname(path)
    when ".txt"        then "text/plain;charset=utf-8"
    when ".html"       then "text/html;charset=utf-8"
    when ".css"        then "text/css;charset=utf-8"
    when ".js", ".mjs" then "application/javascript"
    when ".png"        then "image/png"
    when ".ico"        then "image/x-icon"
    when ".jpg"        then "image/jpeg"
    when ".gif"        then "image/gif"
    when ".svg"        then "image/svg+xml"
    when ".webp"       then "image/webp"
    when ".yaml"       then "application/yaml"
    else                    "application/octet-stream"
    end
  end
end

Log.setup(:info)
DashboardProxy.run(ARGV)
