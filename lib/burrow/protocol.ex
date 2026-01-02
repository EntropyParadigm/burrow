defmodule Burrow.Protocol do
  @moduledoc """
  Binary wire protocol for Burrow tunneling.

  ## Frame Format

      ┌────────┬────────┬────────────────────────────────────────────┐
      │ Length │  Type  │              Payload                       │
      │ 4 bytes│ 1 byte │           Variable                         │
      └────────┴────────┴────────────────────────────────────────────┘

  All integers are big-endian.
  """

  # Frame types
  @auth 0x01
  @auth_ok 0x02
  @auth_fail 0x03
  @tunnel_req 0x10
  @tunnel_ok 0x11
  @tunnel_fail 0x12
  @data 0x20
  @ping 0x30
  @pong 0x31
  @close 0x40
  @shutdown 0x41

  # Type accessors
  def type_auth, do: @auth
  def type_auth_ok, do: @auth_ok
  def type_auth_fail, do: @auth_fail
  def type_tunnel_req, do: @tunnel_req
  def type_tunnel_ok, do: @tunnel_ok
  def type_tunnel_fail, do: @tunnel_fail
  def type_data, do: @data
  def type_ping, do: @ping
  def type_pong, do: @pong
  def type_close, do: @close
  def type_shutdown, do: @shutdown

  @doc """
  Encode a frame for transmission.

  ## Examples

      iex> Burrow.Protocol.encode(:auth, %{token: "secret"})
      <<0, 0, 0, 19, 1, ...>>

  """
  @spec encode(atom(), map() | binary()) :: binary()
  def encode(type, payload) do
    type_byte = type_to_byte(type)
    payload_binary = encode_payload(type, payload)
    length = byte_size(payload_binary) + 1

    <<length::32, type_byte::8, payload_binary::binary>>
  end

  @doc """
  Decode a frame from binary data.

  Returns `{:ok, type, payload, rest}` or `{:incomplete, data}` or `{:error, reason}`.
  """
  @spec decode(binary()) :: {:ok, atom(), map(), binary()} | {:incomplete, binary()} | {:error, term()}
  def decode(<<length::32, type::8, rest::binary>> = data) when byte_size(rest) >= length - 1 do
    payload_length = length - 1
    <<payload::binary-size(payload_length), remaining::binary>> = rest

    case decode_payload(type, payload) do
      {:ok, decoded} ->
        {:ok, byte_to_type(type), decoded, remaining}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def decode(data) when is_binary(data), do: {:incomplete, data}

  @doc """
  Encode an AUTH frame.
  """
  def encode_auth(token) do
    encode(:auth, %{token: token})
  end

  @doc """
  Encode an AUTH_OK frame.
  """
  def encode_auth_ok(client_id) do
    encode(:auth_ok, %{client_id: client_id})
  end

  @doc """
  Encode an AUTH_FAIL frame.
  """
  def encode_auth_fail(reason) do
    encode(:auth_fail, %{reason: reason})
  end

  @doc """
  Encode a TUNNEL_REQ frame.
  """
  def encode_tunnel_req(tunnel_id, name, remote_port, protocol \\ :tcp) do
    encode(:tunnel_req, %{
      tunnel_id: tunnel_id,
      name: name,
      remote_port: remote_port,
      protocol: protocol
    })
  end

  @doc """
  Encode a TUNNEL_OK frame.
  """
  def encode_tunnel_ok(tunnel_id, assigned_port) do
    encode(:tunnel_ok, %{tunnel_id: tunnel_id, port: assigned_port})
  end

  @doc """
  Encode a TUNNEL_FAIL frame.
  """
  def encode_tunnel_fail(tunnel_id, reason) do
    encode(:tunnel_fail, %{tunnel_id: tunnel_id, reason: reason})
  end

  @doc """
  Encode a DATA frame.
  """
  def encode_data(tunnel_id, connection_id, data) do
    encode(:data, %{tunnel_id: tunnel_id, connection_id: connection_id, data: data})
  end

  @doc """
  Encode a PING frame.
  """
  def encode_ping(timestamp \\ System.monotonic_time(:millisecond)) do
    encode(:ping, %{timestamp: timestamp})
  end

  @doc """
  Encode a PONG frame.
  """
  def encode_pong(timestamp) do
    encode(:pong, %{timestamp: timestamp})
  end

  @doc """
  Encode a CLOSE frame.
  """
  def encode_close(tunnel_id, connection_id) do
    encode(:close, %{tunnel_id: tunnel_id, connection_id: connection_id})
  end

  @doc """
  Encode a SHUTDOWN frame.
  """
  def encode_shutdown(reason \\ "normal") do
    encode(:shutdown, %{reason: reason})
  end

  # Private functions

  defp type_to_byte(:auth), do: @auth
  defp type_to_byte(:auth_ok), do: @auth_ok
  defp type_to_byte(:auth_fail), do: @auth_fail
  defp type_to_byte(:tunnel_req), do: @tunnel_req
  defp type_to_byte(:tunnel_ok), do: @tunnel_ok
  defp type_to_byte(:tunnel_fail), do: @tunnel_fail
  defp type_to_byte(:data), do: @data
  defp type_to_byte(:ping), do: @ping
  defp type_to_byte(:pong), do: @pong
  defp type_to_byte(:close), do: @close
  defp type_to_byte(:shutdown), do: @shutdown

  defp byte_to_type(@auth), do: :auth
  defp byte_to_type(@auth_ok), do: :auth_ok
  defp byte_to_type(@auth_fail), do: :auth_fail
  defp byte_to_type(@tunnel_req), do: :tunnel_req
  defp byte_to_type(@tunnel_ok), do: :tunnel_ok
  defp byte_to_type(@tunnel_fail), do: :tunnel_fail
  defp byte_to_type(@data), do: :data
  defp byte_to_type(@ping), do: :ping
  defp byte_to_type(@pong), do: :pong
  defp byte_to_type(@close), do: :close
  defp byte_to_type(@shutdown), do: :shutdown
  defp byte_to_type(unknown), do: {:unknown, unknown}

  # Payload encoding
  defp encode_payload(:auth, %{token: token}) do
    token_bytes = byte_size(token)
    <<token_bytes::16, token::binary>>
  end

  defp encode_payload(:auth_ok, %{client_id: client_id}) do
    id_bytes = byte_size(client_id)
    <<id_bytes::16, client_id::binary>>
  end

  defp encode_payload(:auth_fail, %{reason: reason}) do
    reason_str = to_string(reason)
    reason_bytes = byte_size(reason_str)
    <<reason_bytes::16, reason_str::binary>>
  end

  defp encode_payload(:tunnel_req, %{tunnel_id: tid, name: name, remote_port: port, protocol: proto}) do
    name_bytes = byte_size(name)
    proto_byte = if proto == :udp, do: 1, else: 0
    <<tid::32, name_bytes::8, name::binary, port::16, proto_byte::8>>
  end

  defp encode_payload(:tunnel_ok, %{tunnel_id: tid, port: port}) do
    <<tid::32, port::16>>
  end

  defp encode_payload(:tunnel_fail, %{tunnel_id: tid, reason: reason}) do
    reason_str = to_string(reason)
    reason_bytes = byte_size(reason_str)
    <<tid::32, reason_bytes::16, reason_str::binary>>
  end

  defp encode_payload(:data, %{tunnel_id: tid, connection_id: cid, data: data}) do
    data_length = byte_size(data)
    <<tid::32, cid::32, data_length::32, data::binary>>
  end

  defp encode_payload(:ping, %{timestamp: ts}) do
    <<ts::64>>
  end

  defp encode_payload(:pong, %{timestamp: ts}) do
    <<ts::64>>
  end

  defp encode_payload(:close, %{tunnel_id: tid, connection_id: cid}) do
    <<tid::32, cid::32>>
  end

  defp encode_payload(:shutdown, %{reason: reason}) do
    reason_str = to_string(reason)
    reason_bytes = byte_size(reason_str)
    <<reason_bytes::16, reason_str::binary>>
  end

  # Payload decoding
  defp decode_payload(@auth, <<token_len::16, token::binary-size(token_len)>>) do
    {:ok, %{token: token}}
  end

  defp decode_payload(@auth_ok, <<id_len::16, client_id::binary-size(id_len)>>) do
    {:ok, %{client_id: client_id}}
  end

  defp decode_payload(@auth_fail, <<reason_len::16, reason::binary-size(reason_len)>>) do
    {:ok, %{reason: reason}}
  end

  defp decode_payload(@tunnel_req, <<tid::32, name_len::8, name::binary-size(name_len), port::16, proto::8>>) do
    protocol = if proto == 1, do: :udp, else: :tcp
    {:ok, %{tunnel_id: tid, name: name, remote_port: port, protocol: protocol}}
  end

  defp decode_payload(@tunnel_ok, <<tid::32, port::16>>) do
    {:ok, %{tunnel_id: tid, port: port}}
  end

  defp decode_payload(@tunnel_fail, <<tid::32, reason_len::16, reason::binary-size(reason_len)>>) do
    {:ok, %{tunnel_id: tid, reason: reason}}
  end

  defp decode_payload(@data, <<tid::32, cid::32, data_len::32, data::binary-size(data_len)>>) do
    {:ok, %{tunnel_id: tid, connection_id: cid, data: data}}
  end

  defp decode_payload(@ping, <<ts::64>>) do
    {:ok, %{timestamp: ts}}
  end

  defp decode_payload(@pong, <<ts::64>>) do
    {:ok, %{timestamp: ts}}
  end

  defp decode_payload(@close, <<tid::32, cid::32>>) do
    {:ok, %{tunnel_id: tid, connection_id: cid}}
  end

  defp decode_payload(@shutdown, <<reason_len::16, reason::binary-size(reason_len)>>) do
    {:ok, %{reason: reason}}
  end

  defp decode_payload(_type, _payload) do
    {:error, :invalid_payload}
  end
end
