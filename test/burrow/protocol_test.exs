defmodule Burrow.ProtocolTest do
  use ExUnit.Case, async: true

  alias Burrow.Protocol

  describe "type accessors" do
    test "returns correct byte values" do
      assert Protocol.type_auth() == 0x01
      assert Protocol.type_auth_ok() == 0x02
      assert Protocol.type_auth_fail() == 0x03
      assert Protocol.type_tunnel_req() == 0x10
      assert Protocol.type_tunnel_ok() == 0x11
      assert Protocol.type_tunnel_fail() == 0x12
      assert Protocol.type_data() == 0x20
      assert Protocol.type_ping() == 0x30
      assert Protocol.type_pong() == 0x31
      assert Protocol.type_close() == 0x40
      assert Protocol.type_shutdown() == 0x41
    end
  end

  describe "encode_auth/1 and decode/1" do
    test "encodes and decodes auth frame" do
      token = "my_secret_token"
      frame = Protocol.encode_auth(token)

      assert {:ok, :auth, %{token: ^token}, <<>>} = Protocol.decode(frame)
    end

    test "handles empty token" do
      frame = Protocol.encode_auth("")
      assert {:ok, :auth, %{token: ""}, <<>>} = Protocol.decode(frame)
    end

    test "handles unicode token" do
      token = "tökèn_with_üñîçödé"
      frame = Protocol.encode_auth(token)
      assert {:ok, :auth, %{token: ^token}, <<>>} = Protocol.decode(frame)
    end
  end

  describe "encode_auth_ok/1 and decode/1" do
    test "encodes and decodes auth_ok frame" do
      client_id = "client_12345"
      frame = Protocol.encode_auth_ok(client_id)

      assert {:ok, :auth_ok, %{client_id: ^client_id}, <<>>} = Protocol.decode(frame)
    end
  end

  describe "encode_auth_fail/1 and decode/1" do
    test "encodes and decodes auth_fail frame with string reason" do
      reason = "invalid_token"
      frame = Protocol.encode_auth_fail(reason)

      assert {:ok, :auth_fail, %{reason: ^reason}, <<>>} = Protocol.decode(frame)
    end

    test "encodes and decodes auth_fail frame with atom reason" do
      frame = Protocol.encode_auth_fail(:unauthorized)

      assert {:ok, :auth_fail, %{reason: "unauthorized"}, <<>>} = Protocol.decode(frame)
    end
  end

  describe "encode_tunnel_req/4 and decode/1" do
    test "encodes and decodes tunnel_req frame with TCP protocol" do
      tunnel_id = 1
      name = "web"
      remote_port = 80
      frame = Protocol.encode_tunnel_req(tunnel_id, name, remote_port, :tcp)

      assert {:ok, :tunnel_req, payload, <<>>} = Protocol.decode(frame)
      assert payload.tunnel_id == tunnel_id
      assert payload.name == name
      assert payload.remote_port == remote_port
      assert payload.protocol == :tcp
    end

    test "encodes and decodes tunnel_req frame with UDP protocol" do
      tunnel_id = 2
      name = "dns"
      remote_port = 53
      frame = Protocol.encode_tunnel_req(tunnel_id, name, remote_port, :udp)

      assert {:ok, :tunnel_req, payload, <<>>} = Protocol.decode(frame)
      assert payload.protocol == :udp
    end

    test "defaults to TCP protocol" do
      frame = Protocol.encode_tunnel_req(1, "test", 8080)

      assert {:ok, :tunnel_req, payload, <<>>} = Protocol.decode(frame)
      assert payload.protocol == :tcp
    end
  end

  describe "encode_tunnel_ok/2 and decode/1" do
    test "encodes and decodes tunnel_ok frame" do
      tunnel_id = 1
      assigned_port = 8080
      frame = Protocol.encode_tunnel_ok(tunnel_id, assigned_port)

      assert {:ok, :tunnel_ok, payload, <<>>} = Protocol.decode(frame)
      assert payload.tunnel_id == tunnel_id
      assert payload.port == assigned_port
    end
  end

  describe "encode_tunnel_fail/2 and decode/1" do
    test "encodes and decodes tunnel_fail frame" do
      tunnel_id = 1
      reason = "port_in_use"
      frame = Protocol.encode_tunnel_fail(tunnel_id, reason)

      assert {:ok, :tunnel_fail, payload, <<>>} = Protocol.decode(frame)
      assert payload.tunnel_id == tunnel_id
      assert payload.reason == reason
    end
  end

  describe "encode_data/3 and decode/1" do
    test "encodes and decodes data frame" do
      tunnel_id = 1
      connection_id = 42
      data = "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"
      frame = Protocol.encode_data(tunnel_id, connection_id, data)

      assert {:ok, :data, payload, <<>>} = Protocol.decode(frame)
      assert payload.tunnel_id == tunnel_id
      assert payload.connection_id == connection_id
      assert payload.data == data
    end

    test "handles binary data" do
      data = <<0, 1, 2, 255, 254, 253>>
      frame = Protocol.encode_data(1, 1, data)

      assert {:ok, :data, payload, <<>>} = Protocol.decode(frame)
      assert payload.data == data
    end

    test "handles large data" do
      data = :crypto.strong_rand_bytes(65535)
      frame = Protocol.encode_data(1, 1, data)

      assert {:ok, :data, payload, <<>>} = Protocol.decode(frame)
      assert payload.data == data
    end
  end

  describe "encode_ping/1 and decode/1" do
    test "encodes and decodes ping frame" do
      timestamp = 1234567890
      frame = Protocol.encode_ping(timestamp)

      assert {:ok, :ping, %{timestamp: ^timestamp}, <<>>} = Protocol.decode(frame)
    end

    test "uses current time when no timestamp provided" do
      frame = Protocol.encode_ping()

      assert {:ok, :ping, %{timestamp: ts}, <<>>} = Protocol.decode(frame)
      assert is_integer(ts)
    end
  end

  describe "encode_pong/1 and decode/1" do
    test "encodes and decodes pong frame" do
      timestamp = 1234567890
      frame = Protocol.encode_pong(timestamp)

      assert {:ok, :pong, %{timestamp: ^timestamp}, <<>>} = Protocol.decode(frame)
    end
  end

  describe "encode_close/2 and decode/1" do
    test "encodes and decodes close frame" do
      tunnel_id = 1
      connection_id = 42
      frame = Protocol.encode_close(tunnel_id, connection_id)

      assert {:ok, :close, payload, <<>>} = Protocol.decode(frame)
      assert payload.tunnel_id == tunnel_id
      assert payload.connection_id == connection_id
    end
  end

  describe "encode_shutdown/1 and decode/1" do
    test "encodes and decodes shutdown frame" do
      reason = "server_maintenance"
      frame = Protocol.encode_shutdown(reason)

      assert {:ok, :shutdown, %{reason: ^reason}, <<>>} = Protocol.decode(frame)
    end

    test "defaults to normal reason" do
      frame = Protocol.encode_shutdown()

      assert {:ok, :shutdown, %{reason: "normal"}, <<>>} = Protocol.decode(frame)
    end
  end

  describe "decode/1 with incomplete data" do
    test "returns incomplete when not enough data for length" do
      assert {:incomplete, <<0, 0, 0>>} = Protocol.decode(<<0, 0, 0>>)
    end

    test "returns incomplete when not enough data for payload" do
      # Length says 10 bytes total, but we only have 5 bytes of payload
      data = <<0, 0, 0, 10, 0x01, "hi">>
      assert {:incomplete, ^data} = Protocol.decode(data)
    end

    test "returns incomplete for empty data" do
      assert {:incomplete, <<>>} = Protocol.decode(<<>>)
    end
  end

  describe "decode/1 with multiple frames" do
    test "returns remaining data after decoding one frame" do
      frame1 = Protocol.encode_ping(100)
      frame2 = Protocol.encode_pong(200)
      combined = frame1 <> frame2

      assert {:ok, :ping, %{timestamp: 100}, remaining} = Protocol.decode(combined)
      assert {:ok, :pong, %{timestamp: 200}, <<>>} = Protocol.decode(remaining)
    end

    test "handles partial second frame" do
      frame1 = Protocol.encode_ping(100)
      partial = <<0, 0, 0, 10>>  # Incomplete frame
      combined = frame1 <> partial

      assert {:ok, :ping, %{timestamp: 100}, ^partial} = Protocol.decode(combined)
      assert {:incomplete, ^partial} = Protocol.decode(partial)
    end
  end

  describe "frame format" do
    test "frame has correct structure: length (4 bytes) + type (1 byte) + payload" do
      frame = Protocol.encode_auth("test")

      # Length should be 1 (type) + 2 (token length prefix) + 4 (token bytes) = 7
      <<length::32, type::8, payload::binary>> = frame
      assert length == 7
      assert type == Protocol.type_auth()
      assert byte_size(payload) == 6  # 2 bytes length + 4 bytes "test"
    end

    test "integers are big-endian" do
      frame = Protocol.encode_tunnel_ok(0x01020304, 0x0506)

      # Decode manually to verify big-endian encoding
      <<_length::32, _type::8, tunnel_id::32-big, port::16-big>> = frame
      assert tunnel_id == 0x01020304
      assert port == 0x0506
    end
  end
end
