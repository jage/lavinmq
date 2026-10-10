module LavinMQ
  module HTTP
    # Accepted sockets inherit TCP_NODELAY from the listener, so a response written in
    # several segments isn't held back for the client's delayed ACK: ~40 ms per request
    # on a kept-alive connection.
    def self.tcp_listener(address, port) : TCPServer
      TCPServer.new(address, port).tap(&.tcp_nodelay = true)
    end
  end
end
