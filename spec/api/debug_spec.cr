require "../spec_helper"

module DebugSpec
  class Probe
    @value = 0
  end

  class Holder
    getter probe = Probe.new
  end

  @@holders = [] of Holder

  def self.holders
    @@holders
  end

  # Fills a stack region with pointers to the current fiber, the way a fiber's frames
  # leave references behind on its stack when it finishes
  @[NoInline]
  def self.leave_references : Nil
    refs = uninitialized StaticArray(Void*, 1024)
    refs.fill(Fiber.current.as(Void*))
    consume(refs.to_unsafe)
  end

  @[NoInline]
  def self.consume(refs : Void**) : Nil
    raise "unexpected" if refs.null?
  end

  # Parks with an uninitialized 16 KiB frame: on a reused stack whatever the previous
  # fiber left there is scanned as this fiber's stack
  @[NoInline]
  def self.park(channel : Channel(Nil)) : Nil
    frame = uninitialized StaticArray(UInt8, 16384)
    wait(channel, frame.to_unsafe)
  end

  @[NoInline]
  def self.wait(channel : Channel(Nil), frame : UInt8*) : Nil
    channel.receive
    frame.value = 1_u8
  end

  # Spawns *count* fibers that leave references to themselves on their stacks and finish,
  # then *count* fibers on the same stacks that park, and returns the channel that
  # releases them
  def self.reuse_stacks(count : Int32) : Channel(Nil)
    done = Channel(Nil).new
    count.times do
      spawn(name: "debug-spec-finished") do
        leave_references
        done.send nil
      end
    end
    count.times { done.receive }
    sleep 10.milliseconds # let them finish and release their stacks
    release = Channel(Nil).new
    count.times do
      spawn(name: "debug-spec-parked") { park(release) }
    end
    sleep 10.milliseconds
    release
  end

  def self.retained_fibers(body : JSON::Any, name : String) : Int32
    body["fibers"]["by_name"].as_a.find { |g| g["name"] == name }.try(&.["count"].as_i) || 0
  end
end

describe LavinMQ::HTTP::DebugController do
  describe "GET /api/debug/fibers" do
    it "lists fibers with state, stack usage and backtrace" do
      with_http_server do |http, _|
        channel = Channel(Nil).new
        spawn(name: "debug-spec-waiter") { channel.receive }
        Fiber.yield
        response = http.get("/api/debug/fibers")
        response.status_code.should eq 200
        body = JSON.parse(response.body)
        body["total"].as_i.should be > 1
        body["states"]["parked"].as_i.should be > 0
        fiber = body["fibers"].as_a.find! { |f| f["name"] == "debug-spec-waiter" }
        fiber["state"].should eq "parked"
        fiber["stack_used"].as_i.should be > 0
        {% if LavinMQ::Debug::Unwind::SUPPORTED %}
          fiber["backtrace"].as_a.map(&.as_s).join('\n').should contain "receive"
        {% end %}
        body["by_name"].as_a.find! { |g| g["name"] == "debug-spec-waiter" }["count"].should eq 1
        channel.send nil
      end
    end

    it "filters by name and skips backtraces" do
      with_http_server do |http, _|
        response = http.get("/api/debug/fibers?name=no-such-fiber&backtrace=false")
        response.status_code.should eq 200
        JSON.parse(response.body)["total"].should eq 0
      end
    end

    it "rejects an invalid limit" do
      with_http_server do |http, _|
        http.get("/api/debug/fibers?limit=-1").status_code.should eq 400
        http.get("/api/debug/heap?limit=x").status_code.should eq 400
      end
    end

    it "refuses non administrators" do
      with_http_server do |http, s|
        s.users.create("arnold", "pw", [LavinMQ::Tag::PolicyMaker])
        hdrs = ::HTTP::Headers{"Authorization" => "Basic YXJub2xkOnB3"}
        http.get("/api/debug/fibers", headers: hdrs).status_code.should eq 403
        http.get("/api/debug/heap", headers: hdrs).status_code.should eq 403
        http.get("/api/debug/retention", headers: hdrs).status_code.should eq 403
        http.put("/api/debug/retention", headers: hdrs, body: %({"enabled": true})).status_code.should eq 403
      end
    end
  end

  describe "GET /api/debug/heap" do
    it "counts live objects by type" do
      with_http_server do |http, _|
        DebugSpec.holders.concat(Array.new(100) { DebugSpec::Holder.new })
        response = http.get("/api/debug/heap?limit=100000")
        response.status_code.should eq 200
        body = JSON.parse(response.body)
        body["stop_the_world_ms"].as_f.should be >= 0
        body["gc"]["heap_size"].as_i.should be > 0
        probes = body["types"].as_a.select { |t| t["type"] == "DebugSpec::Probe" }
        probes.sum(&.["count"].as_i).should be >= 100
        probes.first["bytes"].as_i.should be >= 100 * instance_sizeof(DebugSpec::Probe)
      ensure
        DebugSpec.holders.clear
      end
    end
  end

  describe "GET /api/debug/holders" do
    it "reports the objects referencing instances of a type" do
      with_http_server do |http, _|
        DebugSpec.holders.concat(Array.new(10) { DebugSpec::Holder.new })
        response = http.get("/api/debug/holders?type=DebugSpec::Probe")
        response.status_code.should eq 200
        body = JSON.parse(response.body)
        body["holders"]["targets"].as_i.should be >= 10
        group = body["holders"]["groups"].as_a.find! { |g| g["holder"] == "DebugSpec::Holder" }
        group["kind"].should eq "heap"
        group["offsets"].as_h.keys.should eq [offsetof(DebugSpec::Holder, @probe).to_s]
        group["targets"].as_i.should be >= 10
      ensure
        DebugSpec.holders.clear
      end
    end

    it "requires a known type" do
      with_http_server do |http, _|
        http.get("/api/debug/holders").status_code.should eq 400
        http.get("/api/debug/holders?type=NoSuchType").status_code.should eq 400
      end
    end
  end

  describe "/api/debug/retention" do
    it "reports finished fibers kept reachable by reused stacks" do
      with_http_server do |http, _|
        http.put("/api/debug/retention", body: %({"enabled": true})).status_code.should eq 200
        release = DebugSpec.reuse_stacks(50)
        response = http.get("/api/debug/retention?holders=true")
        response.status_code.should eq 200
        body = JSON.parse(response.body)
        body["enabled"].should be_true
        body["tracked_total"].as_i.should be >= 50
        DebugSpec.retained_fibers(body, "debug-spec-finished").should be >= 25
        groups = body["fibers"]["holders"]["groups"].as_a
        group = groups.find! { |g| g["kind"] == "stack" && g["holder"] == "debug-spec-parked" }
        group["same_stack"].as_i.should be > 0
        50.times { release.send nil }
      ensure
        http.put("/api/debug/retention", body: %({"enabled": false}))
      end
    end

    it "doesn't report finished fibers that were collected" do
      with_http_server do |http, _|
        http.put("/api/debug/retention", body: %({"enabled": true})).status_code.should eq 200
        done = Channel(Nil).new
        50.times { spawn(name: "debug-spec-collected") { done.send nil } }
        50.times { done.receive }
        # The schedulers' run queues keep references to the last 256 fibers they ran
        1000.times { spawn(name: "debug-spec-flush") { done.send nil } }
        1000.times { done.receive }
        sleep 10.milliseconds
        body = JSON.parse(http.get("/api/debug/retention").body)
        body["tracked_total"].as_i.should be >= 1050
        DebugSpec.retained_fibers(body, "debug-spec-collected").should be < 10
      ensure
        http.put("/api/debug/retention", body: %({"enabled": false}))
      end
    end

    it "tracks closed sockets" do
      with_http_server do |http, _|
        http.put("/api/debug/retention", body: %({"enabled": true})).status_code.should eq 200
        sockets = Array.new(3) { TCPSocket.new(http.addr.address, http.addr.port) }
        sockets.each &.close
        body = JSON.parse(http.get("/api/debug/retention").body)
        tcp = body["sockets"]["by_type"].as_a.find! { |g| g["name"] == "TCPSocket" }
        tcp["count"].as_i.should be >= 3
        sockets.size.should eq 3 # keeps them reachable until here
      ensure
        http.put("/api/debug/retention", body: %({"enabled": false}))
      end
    end

    it "is off by default and forgets everything when disabled" do
      with_http_server do |http, _|
        body = JSON.parse(http.get("/api/debug/retention").body)
        body["enabled"].should be_false
        body["tracked_total"].should eq 0
        http.put("/api/debug/retention", body: %({"enabled": true}))
        spawn { }
        Fiber.yield
        http.put("/api/debug/retention", body: %({"enabled": false})).body.should eq %({"enabled":false})
        JSON.parse(http.get("/api/debug/retention").body)["tracked_total"].should eq 0
      end
    end

    it "requires a boolean" do
      with_http_server do |http, _|
        http.put("/api/debug/retention", body: %({"enabled": "yes"})).status_code.should eq 400
      end
    end
  end
end
