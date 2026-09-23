require "../spec_helper"
require "lz4"

module ClientProtocolSpec
  extend ClusteringSpecHelper

  # Accepts one follower connection as a leader of the given protocol version
  # would: a leader answers a header it doesn't know with its own and closes.
  # Otherwise it authenticates the follower and serves an empty full sync.
  # Yields the socket once the full sync is done.
  def self.leader_connection(tcp_server, start : Bytes, & : TCPSocket ->)
    io = tcp_server.accept
    header = Bytes.new(start.size)
    io.read_fully(header)
    if header != start
      io.write start
      return
    end
    len = io.read_bytes UInt8, IO::ByteFormat::LittleEndian
    io.skip(len)
    io.write_byte 0u8
    io.read_bytes Int32, IO::ByteFormat::LittleEndian # follower id
    simulate_leader(io, Hash(String, String).new, rounds: 2)
    yield io
  ensure
    io.try &.close
  end

  def self.connect(tcp_server) : {TCPSocket, Compress::LZ4::Reader}
    socket = TCPSocket.new("localhost", tcp_server.local_address.port)
    {socket, Compress::LZ4::Reader.new(socket)}
  end

  describe LavinMQ::Clustering::Client do
    it "acks its full sync to the leader" do
      with_datadir do |data_dir|
        client = make_client(data_dir)
        tcp_server = TCPServer.new("localhost", 0)
        ack = Channel(Int64).new(1)
        spawn do
          leader_connection(tcp_server, LavinMQ::Clustering::Start) do |io|
            ack.send io.read_bytes(Int64, IO::ByteFormat::LittleEndian)
          end
        end
        socket, lz4 = connect(tcp_server)
        client.sync_public(socket, lz4)
        select
        when value = ack.receive
          value.should eq LavinMQ::Clustering::SyncAck
        when timeout(2.seconds)
          fail "no sync ack"
        end
      ensure
        socket.try &.close
        tcp_server.try &.close
        client.try { |c| close_client(c) }
      end
    end

    it "falls back to protocol 1.0 for a 1.0 leader, without a sync ack" do
      with_datadir do |data_dir|
        client = make_client(data_dir)
        tcp_server = TCPServer.new("localhost", 0)
        after_sync = Channel(UInt8?).new(1)
        spawn do
          2.times do # rejects the 1.1 header, then serves the 1.0 reconnect
            leader_connection(tcp_server, LavinMQ::Clustering::LegacyStart) do |io|
              io.read_timeout = 300.milliseconds
              after_sync.send(io.read_byte)
            rescue IO::TimeoutError
              after_sync.send(nil)
            end
          end
        end

        socket, lz4 = connect(tcp_server)
        expect_raises(IO::Error, /protocol 1.0/) { client.sync_public(socket, lz4) }
        socket.close

        socket, lz4 = connect(tcp_server)
        client.sync_public(socket, lz4)
        select
        when byte = after_sync.receive
          byte.should be_nil
        when timeout(2.seconds)
          fail "1.0 leader never finished the sync"
        end
      ensure
        socket.try &.close
        tcp_server.try &.close
        client.try { |c| close_client(c) }
      end
    end
  end
end
