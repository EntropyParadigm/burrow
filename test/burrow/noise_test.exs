defmodule Burrow.NoiseTest do
  use ExUnit.Case, async: true

  alias Burrow.Noise
  alias Burrow.Noise.{Keys, Handshake}

  describe "generate_keypair/0" do
    test "generates valid keypair" do
      {:ok, keypair} = Noise.generate_keypair()

      assert Keys.valid?(keypair)
    end
  end

  describe "Handshake" do
    setup do
      {:ok, server_keys} = Keys.generate()
      {:ok, client_keys} = Keys.generate()

      {:ok, server_keys: server_keys, client_keys: client_keys}
    end

    test "initiator creation requires server pubkey", %{client_keys: client_keys, server_keys: server_keys} do
      assert {:ok, _state} = Handshake.new_initiator(client_keys, server_keys.public)
    end

    test "responder creation succeeds", %{server_keys: server_keys} do
      assert {:ok, _state} = Handshake.new_responder(server_keys)
    end

    test "complete handshake flow", %{client_keys: client_keys, server_keys: server_keys} do
      # Create both sides
      {:ok, initiator} = Handshake.new_initiator(client_keys, server_keys.public)
      {:ok, responder} = Handshake.new_responder(server_keys)

      # Initiator sends first message
      {:ok, msg1, initiator} = Handshake.write_message(initiator, <<>>)
      assert is_binary(msg1)
      refute Handshake.complete?(initiator)

      # Responder processes first message
      {:ok, _payload, responder} = Handshake.read_message(responder, msg1)
      refute Handshake.complete?(responder)

      # Responder sends response
      {:ok, msg2, responder} = Handshake.write_message(responder, <<>>)
      assert is_binary(msg2)
      assert Handshake.complete?(responder)

      # Initiator processes response
      {:ok, _payload, initiator} = Handshake.read_message(initiator, msg2)
      assert Handshake.complete?(initiator)

      # Both can now use the completed handshake state for encryption
      # Test encrypt/decrypt works
      {:ok, ciphertext, _new_initiator} = Handshake.encrypt(initiator, "test message")
      assert is_binary(ciphertext)

      {:ok, plaintext, _new_responder} = Handshake.decrypt(responder, ciphertext)
      assert plaintext == "test message"
    end

    test "handshake with payload", %{client_keys: client_keys, server_keys: server_keys} do
      {:ok, initiator} = Handshake.new_initiator(client_keys, server_keys.public)
      {:ok, responder} = Handshake.new_responder(server_keys)

      # Send payload in first message
      payload1 = "hello from client"
      {:ok, msg1, initiator} = Handshake.write_message(initiator, payload1)

      # Responder should receive payload
      {:ok, received_payload, responder} = Handshake.read_message(responder, msg1)
      assert received_payload == payload1

      # Response with payload
      payload2 = "hello from server"
      {:ok, msg2, responder} = Handshake.write_message(responder, payload2)

      {:ok, received_payload2, _initiator} = Handshake.read_message(initiator, msg2)
      assert received_payload2 == payload2
    end
  end

  describe "Transport encryption" do
    setup do
      {:ok, server_keys} = Keys.generate()
      {:ok, client_keys} = Keys.generate()

      # Complete handshake to get handshake states for encryption
      {:ok, initiator} = Handshake.new_initiator(client_keys, server_keys.public)
      {:ok, responder} = Handshake.new_responder(server_keys)

      {:ok, msg1, initiator} = Handshake.write_message(initiator, <<>>)
      {:ok, _, responder} = Handshake.read_message(responder, msg1)
      {:ok, msg2, responder} = Handshake.write_message(responder, <<>>)
      {:ok, _, initiator} = Handshake.read_message(initiator, msg2)

      {:ok, client_hs: initiator, server_hs: responder}
    end

    test "encrypt and decrypt round trip", context do
      # Test encryption directly using Handshake module
      plaintext = "Hello, encrypted world!"

      {:ok, ciphertext, _client_hs} = Handshake.encrypt(context.client_hs, plaintext)
      {:ok, decrypted, _server_hs} = Handshake.decrypt(context.server_hs, ciphertext)

      assert decrypted == plaintext
    end

    test "bidirectional encryption", context do
      # Client -> Server
      msg1 = "From client to server"
      {:ok, enc1, client_hs} = Handshake.encrypt(context.client_hs, msg1)
      {:ok, dec1, server_hs} = Handshake.decrypt(context.server_hs, enc1)
      assert dec1 == msg1

      # Server -> Client
      msg2 = "From server to client"
      {:ok, enc2, _server_hs} = Handshake.encrypt(server_hs, msg2)
      {:ok, dec2, _client_hs} = Handshake.decrypt(client_hs, enc2)
      assert dec2 == msg2
    end
  end
end
