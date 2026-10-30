# Candidate fix: a pooled fiber stack keeps the previous fiber's stack contents, and a new fiber's
# uninitialized stack slots can still point at that dead fiber, so the GC (which scans parked
# fibers' stacks conservatively) keeps the dead fiber, its closure and its socket alive. Drop the
# pages when a stack is reused so they read as zeros.
{% if flag?(:unix) %}
  module Crystal::System::Fiber
    def self.reset_stack(stack : Void*, stack_size : Int, protect : Bool) : Nil
      LibC.madvise(stack, stack_size, LibC::MADV_DONTNEED)
    end
  end
{% end %}
