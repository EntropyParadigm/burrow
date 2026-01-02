defmodule Burrow.IPFilter do
  @moduledoc """
  IP allowlist/blocklist filtering for Burrow server.

  Supports:
  - Single IP addresses (IPv4 and IPv6)
  - CIDR notation for subnets (e.g., "192.168.1.0/24")
  - Mixed allowlist and blocklist modes

  ## Configuration

      config :burrow, :ip_filter,
        enabled: true,
        mode: :allowlist,  # :allowlist or :blocklist
        addresses: [
          "192.168.1.0/24",
          "10.0.0.0/8",
          "203.0.113.50"
        ]

  ## Usage

      # Check if IP is allowed
      case Burrow.IPFilter.allowed?("192.168.1.100") do
        true -> # Allow connection
        false -> # Reject
      end

  """

  require Logger
  import Bitwise

  @doc """
  Check if an IP address is allowed based on current configuration.

  Returns `true` if:
  - IP filtering is disabled
  - Mode is :allowlist and IP matches a configured address/subnet
  - Mode is :blocklist and IP does NOT match any configured address/subnet
  """
  @spec allowed?(String.t() | tuple()) :: boolean()
  def allowed?(ip) do
    config = Application.get_env(:burrow, :ip_filter, %{})
    enabled = Map.get(config, :enabled, false)

    if enabled do
      check_ip(ip, config)
    else
      true
    end
  end

  @doc """
  Check if IP filtering is enabled.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    config = Application.get_env(:burrow, :ip_filter, %{})
    Map.get(config, :enabled, false)
  end

  @doc """
  Parse a CIDR notation string into {ip_tuple, prefix_length}.
  """
  @spec parse_cidr(String.t()) :: {:ok, {tuple(), non_neg_integer()}} | {:error, :invalid_cidr}
  def parse_cidr(cidr) when is_binary(cidr) do
    case String.split(cidr, "/") do
      [ip_str, prefix_str] ->
        with {:ok, ip} <- parse_ip(ip_str),
             {prefix, ""} <- Integer.parse(prefix_str),
             true <- valid_prefix?(ip, prefix) do
          {:ok, {ip, prefix}}
        else
          _ -> {:error, :invalid_cidr}
        end

      [ip_str] ->
        case parse_ip(ip_str) do
          {:ok, ip} when tuple_size(ip) == 4 -> {:ok, {ip, 32}}
          {:ok, ip} when tuple_size(ip) == 8 -> {:ok, {ip, 128}}
          _ -> {:error, :invalid_cidr}
        end

      _ ->
        {:error, :invalid_cidr}
    end
  end

  @doc """
  Check if an IP address matches a CIDR range.
  """
  @spec matches_cidr?(tuple(), tuple(), non_neg_integer()) :: boolean()
  def matches_cidr?(ip, network, prefix) when tuple_size(ip) == tuple_size(network) do
    ip_bits = ip_to_bits(ip)
    network_bits = ip_to_bits(network)

    # Compare the first `prefix` bits
    ip_prefix = binary_part(ip_bits, 0, div(prefix, 8) + if(rem(prefix, 8) > 0, do: 1, else: 0))
    network_prefix = binary_part(network_bits, 0, div(prefix, 8) + if(rem(prefix, 8) > 0, do: 1, else: 0))

    # Mask the last byte if prefix is not on a byte boundary
    remainder = rem(prefix, 8)
    if remainder > 0 do
      mask = 0xFF <<< (8 - remainder)
      ip_masked = mask_last_byte(ip_prefix, mask)
      network_masked = mask_last_byte(network_prefix, mask)
      ip_masked == network_masked
    else
      ip_prefix == network_prefix
    end
  end

  def matches_cidr?(_, _, _), do: false

  # Private functions

  defp check_ip(ip, config) do
    mode = Map.get(config, :mode, :allowlist)
    addresses = Map.get(config, :addresses, [])

    ip_tuple = normalize_ip(ip)
    matches = ip_matches_any?(ip_tuple, addresses)

    case mode do
      :allowlist -> matches
      :blocklist -> not matches
    end
  end

  defp normalize_ip(ip) when is_binary(ip) do
    case parse_ip(ip) do
      {:ok, tuple} -> tuple
      _ -> nil
    end
  end

  defp normalize_ip({_, _, _, _} = ip), do: ip
  defp normalize_ip({_, _, _, _, _, _, _, _} = ip), do: ip
  defp normalize_ip(_), do: nil

  defp parse_ip(ip_str) when is_binary(ip_str) do
    ip_str = String.trim(ip_str)

    case :inet.parse_address(String.to_charlist(ip_str)) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> {:error, :invalid_ip}
    end
  end

  defp ip_matches_any?(nil, _), do: false
  defp ip_matches_any?(ip, addresses) do
    Enum.any?(addresses, fn addr ->
      case parse_cidr(addr) do
        {:ok, {network, prefix}} -> matches_cidr?(ip, network, prefix)
        _ -> false
      end
    end)
  end

  defp valid_prefix?({_, _, _, _}, prefix), do: prefix >= 0 and prefix <= 32
  defp valid_prefix?({_, _, _, _, _, _, _, _}, prefix), do: prefix >= 0 and prefix <= 128
  defp valid_prefix?(_, _), do: false

  defp ip_to_bits({a, b, c, d}) do
    <<a::8, b::8, c::8, d::8>>
  end

  defp ip_to_bits({a, b, c, d, e, f, g, h}) do
    <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>
  end

  defp mask_last_byte(binary, mask) when byte_size(binary) > 0 do
    size = byte_size(binary) - 1
    <<prefix::binary-size(size), last::8>> = binary
    <<prefix::binary, last &&& mask::8>>
  end

  defp mask_last_byte(binary, _), do: binary
end
