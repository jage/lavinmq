require "socket"

{% unless flag?(:gc_none) %}
  # Bench copy: counts unregistrations and, with GC_PAUSE_FILE set, appends
  # "ticks total" to $GC_PAUSE_FILE.unregs once a second.
  module SocketUnregister
    @@count = Atomic(UInt64).new(0_u64)

    def self.bump : Nil
      @@count.add(1_u64, :relaxed)
    end

    def self.count : UInt64
      @@count.get(:relaxed)
    end
  end

  class Socket
    private def unbuffered_close : Nil
      return if @closed

      begin
        previous_def
      ensure
        # `finalize` is a no-op once closed; dropping it lets the GC free us a cycle sooner
        LibGC.register_finalizer_ignore_self(as(Void*),
          LibGC::Finalizer.new(Pointer(Void).null, Pointer(Void).null), nil, nil, nil)
        SocketUnregister.bump
      end
    end
  end

  if unregs_path = ENV["GC_PAUSE_FILE"]?
    started = Time.instant
    spawn(name: "socket unregistrations") do
      File.open("#{unregs_path}.unregs", "a") do |f|
        loop do
          sleep 1.second
          f.puts "#{Crystal::System::Time.ticks} #{SocketUnregister.count}"
          f.flush
        end
      end
    end
    at_exit do
      secs = (Time.instant - started).total_seconds
      STDERR.puts "socket finalizer unregistrations: #{SocketUnregister.count} (#{(SocketUnregister.count / secs).round(1)}/s over #{secs.round}s)"
    end
  end
{% end %}
