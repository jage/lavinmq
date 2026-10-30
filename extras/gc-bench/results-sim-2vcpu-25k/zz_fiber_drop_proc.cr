# Candidate fix: a finished fiber keeps its proc, so the closure (for a connection's read loop: the
# client socket, and through it the socket's buffers) lives as long as the dead Fiber object. A
# newly started fiber keeps an interior pointer to the fiber that first switched to it in its
# bottom frames, so dead fibers stay reachable while their successors live. Drop the proc when a
# fiber finishes, after it has returned.
class Fiber
  # :nodoc:
  def self.inactive(fiber : Fiber)
    previous_def
    fiber.drop_proc
  end

  # :nodoc:
  def drop_proc : Nil
    @proc = -> { }
  end
end
