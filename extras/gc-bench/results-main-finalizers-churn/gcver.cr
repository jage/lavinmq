lib LibGC
  fun get_version = GC_get_version : UInt32
end
v = LibGC.get_version
puts "GC_get_version #{v >> 16}.#{(v >> 8) & 0xff}.#{v & 0xff}"
