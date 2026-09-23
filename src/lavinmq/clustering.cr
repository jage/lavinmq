require "log"
require "socket"
require "digest/sha1"

module LavinMQ
  module Clustering
    # Handshake header, ending with the protocol version. A 1.1 follower acks
    # its full sync once it's on disk, and only then joins the ISR.
    Start = Bytes['R'.ord, 'E'.ord, 'P'.ord, 'L'.ord, 'I'.ord, 1, 1, 0]
    # Protocol 1.0: the follower joins the ISR as soon as its full sync is sent.
    LegacyStart = Bytes['R'.ord, 'E'.ord, 'P'.ord, 'L'.ord, 'I'.ord, 1, 0, 0]
    # Sent by a 1.1 follower after its full sync, before any stream ack.
    SyncAck = -1i64

    class Error < Exception; end

    class InvalidStartHeaderError < Error
      def initialize(bytes)
        super("Invalid start header: #{bytes} #{String.new(bytes)} ")
      end
    end

    class AuthenticationError < Error
      def initialize
        super("Authentication error")
      end
    end
  end
end
