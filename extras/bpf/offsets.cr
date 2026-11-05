# Prints the Fiber/String field offsets the bpftrace scripts need, for the
# Crystal version (and target) this file is compiled with. Used to fill the
# offset table in lavinmq-bpf for release binaries that carry no type DWARF:
#
#   crystal run extras/bpf/offsets.cr
#
# For another target, read the same fields from the DWARF of a cross-compiled
# object (the layout is the same on x86_64 and aarch64):
#
#   crystal build --cross-compile --target aarch64-linux-gnu --debug extras/bpf/offsets.cr
#   llvm-dwarfdump --name=Fiber -c offsets.o
#
puts "crystal=#{Crystal::VERSION}"
puts "fiber_context=#{offsetof(Fiber, @context)}"
puts "fiber_name=#{offsetof(Fiber, @name)}"
puts "string_bytesize=#{offsetof(String, @bytesize)}"
puts "string_data=#{offsetof(String, @c)}"
