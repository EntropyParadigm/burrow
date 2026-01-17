defmodule Burrow.Noise.Keys do
  @moduledoc """
  Key management for Noise protocol encryption.

  Handles generation, serialization, and storage of X25519 keypairs
  used in the Noise_IK handshake pattern.

  ## Usage

      # Generate a new keypair
      {:ok, keypair} = Burrow.Noise.Keys.generate()

      # Get public key in base64
      pubkey = Burrow.Noise.Keys.public_key_base64(keypair)

      # Save keypair to file
      :ok = Burrow.Noise.Keys.save(keypair, "/path/to/server.key")

      # Load keypair from file
      {:ok, keypair} = Burrow.Noise.Keys.load("/path/to/server.key")

  """

  @key_size 32
  @file_header "BURROW-NOISE-KEY-V1\n"

  @type keypair :: %{public: binary(), private: binary()}

  @doc """
  Generate a new X25519 keypair for Noise protocol.

  Returns `{:ok, keypair}` where keypair is a map with `:public` and `:private` keys.
  """
  @spec generate() :: {:ok, keypair()}
  def generate do
    {public, private} = :crypto.generate_key(:ecdh, :x25519)
    {:ok, %{public: public, private: private}}
  end

  @doc """
  Generate a new keypair, raising on error.
  """
  @spec generate!() :: keypair()
  def generate! do
    {:ok, keypair} = generate()
    keypair
  end

  @doc """
  Encode the public key as base64.
  """
  @spec public_key_base64(keypair()) :: String.t()
  def public_key_base64(%{public: public}) do
    Base.encode64(public)
  end

  @doc """
  Decode a base64 public key.

  Returns `{:ok, public_key}` or `{:error, reason}`.
  """
  @spec decode_public_key(String.t()) :: {:ok, binary()} | {:error, term()}
  def decode_public_key(base64) when is_binary(base64) do
    case Base.decode64(base64) do
      {:ok, key} when byte_size(key) == @key_size ->
        {:ok, key}

      {:ok, key} ->
        {:error, {:invalid_key_size, byte_size(key)}}

      :error ->
        {:error, :invalid_base64}
    end
  end

  @doc """
  Decode a base64 public key, raising on error.
  """
  @spec decode_public_key!(String.t()) :: binary()
  def decode_public_key!(base64) do
    case decode_public_key(base64) do
      {:ok, key} -> key
      {:error, reason} -> raise "Failed to decode public key: #{inspect(reason)}"
    end
  end

  @doc """
  Save a keypair to a file.

  The file format is:
  - Header line: "BURROW-NOISE-KEY-V1\\n"
  - Private key (32 bytes, base64 encoded)
  - Public key (32 bytes, base64 encoded)
  """
  @spec save(keypair(), Path.t()) :: :ok | {:error, term()}
  def save(%{public: public, private: private}, path) do
    content = @file_header <>
      "private:" <> Base.encode64(private) <> "\n" <>
      "public:" <> Base.encode64(public) <> "\n"

    case File.write(path, content) do
      :ok ->
        # Set restrictive permissions (owner read/write only)
        File.chmod(path, 0o600)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Save a keypair to a file, raising on error.
  """
  @spec save!(keypair(), Path.t()) :: :ok
  def save!(keypair, path) do
    case save(keypair, path) do
      :ok -> :ok
      {:error, reason} -> raise "Failed to save key: #{inspect(reason)}"
    end
  end

  @doc """
  Load a keypair from a file.

  Returns `{:ok, keypair}` or `{:error, reason}`.
  """
  @spec load(Path.t()) :: {:ok, keypair()} | {:error, term()}
  def load(path) do
    with {:ok, content} <- File.read(path),
         {:ok, keypair} <- parse_key_file(content) do
      {:ok, keypair}
    end
  end

  @doc """
  Load a keypair from a file, raising on error.
  """
  @spec load!(Path.t()) :: keypair()
  def load!(path) do
    case load(path) do
      {:ok, keypair} -> keypair
      {:error, reason} -> raise "Failed to load key from #{path}: #{inspect(reason)}"
    end
  end

  @doc """
  Extract just the public key from a keypair.
  """
  @spec public_key(keypair()) :: binary()
  def public_key(%{public: public}), do: public

  @doc """
  Extract just the private key from a keypair.
  """
  @spec private_key(keypair()) :: binary()
  def private_key(%{private: private}), do: private

  @doc """
  Validate that a keypair is properly formed.
  """
  @spec valid?(keypair()) :: boolean()
  def valid?(%{public: public, private: private})
      when byte_size(public) == @key_size and byte_size(private) == @key_size do
    true
  end

  def valid?(_), do: false

  # Private functions

  defp parse_key_file(content) do
    lines = String.split(content, "\n", trim: true)

    with [header | key_lines] <- lines,
         true <- String.starts_with?(header, "BURROW-NOISE-KEY"),
         {:ok, keys} <- parse_key_lines(key_lines) do
      {:ok, keys}
    else
      false -> {:error, :invalid_header}
      [] -> {:error, :empty_file}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_key_lines(lines) do
    result =
      Enum.reduce_while(lines, %{}, fn line, acc ->
        case String.split(line, ":", parts: 2) do
          ["private", value] ->
            case Base.decode64(String.trim(value)) do
              {:ok, key} when byte_size(key) == @key_size ->
                {:cont, Map.put(acc, :private, key)}

              _ ->
                {:halt, {:error, :invalid_private_key}}
            end

          ["public", value] ->
            case Base.decode64(String.trim(value)) do
              {:ok, key} when byte_size(key) == @key_size ->
                {:cont, Map.put(acc, :public, key)}

              _ ->
                {:halt, {:error, :invalid_public_key}}
            end

          _ ->
            {:cont, acc}
        end
      end)

    case result do
      %{public: _, private: _} = keypair -> {:ok, keypair}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :incomplete_keypair}
    end
  end
end
