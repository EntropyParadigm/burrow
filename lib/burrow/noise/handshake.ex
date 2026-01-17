defmodule Burrow.Noise.Handshake do
  @moduledoc """
  Noise protocol handshake implementation using the Noise_IK pattern.

  The IK pattern is ideal for Burrow because:
  - The client knows the server's public key ahead of time (via CLI/config)
  - 1-RTT handshake: Client sends first message, server responds, done
  - Forward secrecy with ephemeral keys
  - Server authentication (client verifies server identity)

  ## Handshake Pattern (Noise_IK)

      -> e, es, s, ss
      <- e, ee, se

  Where:
  - `e` = ephemeral key
  - `s` = static key
  - `es`, `ee`, `se`, `ss` = DH operations

  ## Usage

  ### Client (Initiator)

      {:ok, state} = Handshake.new_initiator(client_keypair, server_public_key)
      {:ok, message1, state} = Handshake.write_message(state, <<>>)
      # Send message1 to server, receive message2
      {:ok, _payload, state} = Handshake.read_message(state, message2)
      true = Handshake.complete?(state)

  ### Server (Responder)

      {:ok, state} = Handshake.new_responder(server_keypair)
      {:ok, _payload, state} = Handshake.read_message(state, message1)
      {:ok, message2, state} = Handshake.write_message(state, <<>>)
      true = Handshake.complete?(state)

  """

  require Logger

  @protocol_name "Noise_IK_25519_ChaChaPoly_SHA256"
  @dh_size 32

  defstruct [
    :role,           # :initiator or :responder
    :ref,            # Decibel reference
    :rs,             # Remote static public key
    :message_count   # Number of messages processed
  ]

  @type role :: :initiator | :responder
  @type keypair :: %{public: binary(), private: binary()}
  @type t :: %__MODULE__{}

  @doc """
  Create a new handshake state for an initiator (client).

  The initiator must know the responder's (server's) static public key.
  """
  @spec new_initiator(keypair(), binary()) :: {:ok, t()} | {:error, term()}
  def new_initiator(static_keypair, remote_static_pubkey)
      when byte_size(remote_static_pubkey) == @dh_size do
    try do
      # Create keys map for Decibel
      # s: local static key pair as tuple {public, private}
      # rs: remote static public key
      keys = %{
        s: {static_keypair.public, static_keypair.private},
        rs: remote_static_pubkey,
        prologue: "Burrow"
      }

      ref = Decibel.new(@protocol_name, :ini, keys)

      state = %__MODULE__{
        role: :initiator,
        ref: ref,
        rs: remote_static_pubkey,
        message_count: 0
      }

      {:ok, state}
    rescue
      e -> {:error, {:handshake_init_failed, Exception.message(e)}}
    end
  end

  @doc """
  Create a new handshake state for a responder (server).
  """
  @spec new_responder(keypair()) :: {:ok, t()} | {:error, term()}
  def new_responder(static_keypair) do
    try do
      keys = %{
        s: {static_keypair.public, static_keypair.private},
        prologue: "Burrow"
      }

      ref = Decibel.new(@protocol_name, :rsp, keys)

      state = %__MODULE__{
        role: :responder,
        ref: ref,
        rs: nil,
        message_count: 0
      }

      {:ok, state}
    rescue
      e -> {:error, {:handshake_init_failed, Exception.message(e)}}
    end
  end

  @doc """
  Write a handshake message.

  Returns `{:ok, message, new_state}` or `{:error, reason}`.
  """
  @spec write_message(t(), binary()) :: {:ok, binary(), t()} | {:error, term()}
  def write_message(%__MODULE__{} = state, payload \\ <<>>) do
    if complete?(state) do
      {:error, :handshake_complete}
    else
      try do
        message = Decibel.handshake_encrypt(state.ref, payload)
        message_binary = IO.iodata_to_binary(message)

        new_state = %{state | message_count: state.message_count + 1}
        {:ok, message_binary, new_state}
      rescue
        e -> {:error, {:write_failed, Exception.message(e)}}
      end
    end
  end

  @doc """
  Read and process a handshake message from the peer.

  Returns `{:ok, payload, new_state}`.
  """
  @spec read_message(t(), binary()) :: {:ok, binary(), t()} | {:error, term()}
  def read_message(%__MODULE__{} = state, message) when is_binary(message) do
    if complete?(state) do
      {:error, :handshake_complete}
    else
      try do
        payload = Decibel.handshake_decrypt(state.ref, message)
        payload_binary = IO.iodata_to_binary(payload)

        # Update remote static key for responder
        rs = state.rs || Decibel.get_remote_key(state.ref)

        new_state = %{state |
          message_count: state.message_count + 1,
          rs: rs
        }

        {:ok, payload_binary, new_state}
      rescue
        e -> {:error, {:read_failed, Exception.message(e)}}
      end
    end
  end

  @doc """
  Check if the handshake is complete.
  """
  @spec complete?(t()) :: boolean()
  def complete?(%__MODULE__{ref: ref}) do
    Decibel.is_handshake_complete?(ref)
  end

  @doc """
  Encrypt a message after handshake completion.
  """
  @spec encrypt(t(), binary()) :: {:ok, binary(), t()} | {:error, term()}
  def encrypt(%__MODULE__{ref: ref} = state, plaintext) do
    try do
      ciphertext = Decibel.encrypt(ref, plaintext)
      {:ok, IO.iodata_to_binary(ciphertext), state}
    rescue
      e -> {:error, {:encrypt_failed, Exception.message(e)}}
    end
  end

  @doc """
  Decrypt a message after handshake completion.
  """
  @spec decrypt(t(), binary()) :: {:ok, binary(), t()} | {:error, term()}
  def decrypt(%__MODULE__{ref: ref} = state, ciphertext) do
    try do
      plaintext = Decibel.decrypt(ref, ciphertext)
      {:ok, IO.iodata_to_binary(plaintext), state}
    rescue
      e -> {:error, {:decrypt_failed, Exception.message(e)}}
    end
  end

  @doc """
  Get the remote peer's static public key.
  """
  @spec remote_static(t()) :: {:ok, binary()} | {:error, term()}
  def remote_static(%__MODULE__{rs: rs}) when is_binary(rs), do: {:ok, rs}
  def remote_static(%__MODULE__{ref: ref}) do
    case Decibel.get_remote_key(ref) do
      nil -> {:error, :not_available}
      key -> {:ok, key}
    end
  end

  @doc """
  Get the handshake hash (for channel binding).
  """
  @spec handshake_hash(t()) :: {:ok, binary()} | {:error, term()}
  def handshake_hash(%__MODULE__{ref: ref}) do
    case Decibel.get_handshake_hash(ref) do
      nil -> {:error, :handshake_not_complete}
      hash -> {:ok, hash}
    end
  end

  @doc """
  Close the handshake and release resources.
  """
  @spec close(t()) :: :ok
  def close(%__MODULE__{ref: ref}) do
    Decibel.close(ref)
  end
end
