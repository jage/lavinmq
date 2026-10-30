require "socket"

{% unless flag?(:gc_none) %}
  # Bench copy: counts unregistrations and appends "ticks count" to $GC_PAUSE_FILE.unregs each second
  module SocketUnregisterCount
    @@n = Atomic(UInt64).new(0_u64)

    def self.bump : Nil
      @@n.add(1_u64, :relaxed)
    end

    def self.get : UInt64
      @@n.get(:relaxed)
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
        SocketUnregisterCount.bump
      end
    end
  end

  if unreg_path = ENV["GC_PAUSE_FILE"]?
    spawn(name: "socket unregister count") do
      File.open("#{unreg_path}.unregs", "a") do |f|
        loop do
          sleep 1.second
          f << Crystal::System::Time.ticks << ' ' << SocketUnregisterCount.get << '\n'
          f.flush
        end
      end
    end
  end
{% end %}
