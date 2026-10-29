# A class which has two channels, one for which a state is true
# and the other for when the state if false
class BoolChannel
  class StateChannel < Channel(Nil)
    class EndlessQueue < Deque(Nil)
      property? empty : Bool = true

      def shift(&)
        yield if empty?
      end

      def push(value : T)
        raise "Can't push to an EndlessQueue"
      end
    end

    @queue = EndlessQueue.new

    def activate
      @lock.sync do
        @queue.as(EndlessQueue).empty = false
        while receiver_ptr = dequeue_receiver
          receiver_ptr.value.data = nil
          receiver_ptr.value.state = DeliveryState::Delivered
          receiver_ptr.value.fiber.enqueue
        end
      end
    end

    def deactivate
      @lock.sync do
        @queue.as(EndlessQueue).empty = true
      end
    end
  end

  @when_true : StateChannel? = nil
  @when_false : StateChannel? = nil
  @closed = false
  @value : Atomic(Bool)
  # Makes updating the value and switching the active channel one step, so
  # concurrent sets can't leave them disagreeing
  @lock = Mutex.new

  def initialize(value : Bool)
    @value = Atomic.new(value)
  end

  # The channels are made on first use: most queues have nothing waiting on most of theirs,
  # and every collection scans the ones that exist
  def when_true : StateChannel
    @lock.synchronize { @when_true ||= state_channel(true) }
  end

  def when_false : StateChannel
    @lock.synchronize { @when_false ||= state_channel(false) }
  end

  private def state_channel(state : Bool) : StateChannel
    channel = StateChannel.new
    channel.activate if @value.get(:acquire) == state
    channel.close if @closed
    channel
  end

  def value
    @value.get(:acquire)
  end

  def swap(value : Bool)
    @lock.synchronize do
      ret = @value.swap(value)
      update_active_channel(value) unless ret == value
      ret
    end
  end

  def set(value : Bool) : Nil
    @lock.synchronize do
      @value.set(value)
      update_active_channel(value)
    end
    nil
  end

  private def update_active_channel(value)
    if value
      @when_false.try &.deactivate
      @when_true.try &.activate
    else
      @when_true.try &.deactivate
      @when_false.try &.activate
    end
  end

  def close
    @lock.synchronize do
      @closed = true
      @when_true.try &.close
      @when_false.try &.close
    end
  end
end
