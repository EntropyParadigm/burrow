defmodule Burrow.Token do
  @moduledoc """
  Token hashing and verification for Burrow authentication.

  Uses Argon2id for secure password hashing.

  ## Usage

  ### Generating a Hash (for server config)

      # Generate a hash for your token
      hash = Burrow.Token.hash("my_secret_token")
      # => "$argon2id$v=19$m=65536,t=3,p=4$..."

  ### Server Configuration

      # Use token_hash instead of token for secure storage
      Burrow.Server.start_link(
        port: 4000,
        token_hash: hash
      )

  ### Verification

      # Verify a token against a hash
      Burrow.Token.verify?("my_secret_token", hash)
      # => true

  ## CLI Usage

      # Generate a hash
      ./burrow hash-token mysecret
      # => $argon2id$v=19$m=65536,t=3,p=4$...

  """

  @doc """
  Hash a token using Argon2id.

  Returns a string that can be stored in configuration files.

  ## Examples

      iex> hash = Burrow.Token.hash("secret")
      iex> String.starts_with?(hash, "$argon2id$")
      true

  """
  @spec hash(String.t()) :: String.t()
  def hash(token) when is_binary(token) do
    Argon2.hash_pwd_salt(token)
  end

  @doc """
  Verify a token against a stored hash.

  Uses constant-time comparison to prevent timing attacks.

  ## Examples

      iex> hash = Burrow.Token.hash("secret")
      iex> Burrow.Token.verify?("secret", hash)
      true
      iex> Burrow.Token.verify?("wrong", hash)
      false

  """
  @spec verify?(String.t(), String.t()) :: boolean()
  def verify?(token, hash) when is_binary(token) and is_binary(hash) do
    Argon2.verify_pass(token, hash)
  end

  @doc """
  Check if a string looks like an Argon2 hash.

  ## Examples

      iex> Burrow.Token.hash?("$argon2id$v=19$m=65536,t=3,p=4$...")
      true
      iex> Burrow.Token.hash?("plaintext_token")
      false

  """
  @spec hash?(String.t()) :: boolean()
  def hash?(value) when is_binary(value) do
    String.starts_with?(value, "$argon2")
  end

  def hash?(_), do: false

  @doc """
  Generate a secure random token.

  ## Options

  - `:length` - Number of random bytes (default: `32`)
  - `:encoding` - `:base64` or `:hex` (default: `:base64`)

  ## Examples

      iex> token = Burrow.Token.generate()
      iex> byte_size(token) > 20
      true

      iex> token = Burrow.Token.generate(length: 16, encoding: :hex)
      iex> String.length(token)
      32

  """
  @spec generate(keyword()) :: String.t()
  def generate(opts \\ []) do
    length = Keyword.get(opts, :length, 32)
    encoding = Keyword.get(opts, :encoding, :base64)

    bytes = :crypto.strong_rand_bytes(length)

    case encoding do
      :hex -> Base.encode16(bytes, case: :lower)
      :base64 -> Base.url_encode64(bytes, padding: false)
      _ -> Base.url_encode64(bytes, padding: false)
    end
  end
end
