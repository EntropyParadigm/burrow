defmodule Burrow.Noise.KeysTest do
  use ExUnit.Case, async: true

  alias Burrow.Noise.Keys

  describe "generate/0" do
    test "generates valid keypair" do
      {:ok, keypair} = Keys.generate()

      assert is_map(keypair)
      assert is_binary(keypair.public)
      assert is_binary(keypair.private)
      assert byte_size(keypair.public) == 32
      assert byte_size(keypair.private) == 32
    end

    test "generates unique keypairs" do
      {:ok, keypair1} = Keys.generate()
      {:ok, keypair2} = Keys.generate()

      assert keypair1.public != keypair2.public
      assert keypair1.private != keypair2.private
    end
  end

  describe "generate!/0" do
    test "generates valid keypair" do
      keypair = Keys.generate!()

      assert Keys.valid?(keypair)
    end
  end

  describe "public_key_base64/1" do
    test "encodes public key as base64" do
      {:ok, keypair} = Keys.generate()
      base64 = Keys.public_key_base64(keypair)

      assert is_binary(base64)
      assert {:ok, decoded} = Base.decode64(base64)
      assert decoded == keypair.public
    end
  end

  describe "decode_public_key/1" do
    test "decodes valid base64 public key" do
      {:ok, keypair} = Keys.generate()
      base64 = Keys.public_key_base64(keypair)

      assert {:ok, decoded} = Keys.decode_public_key(base64)
      assert decoded == keypair.public
    end

    test "returns error for invalid base64" do
      assert {:error, :invalid_base64} = Keys.decode_public_key("not valid base64!!!")
    end

    test "returns error for wrong size key" do
      short_key = Base.encode64(<<1, 2, 3, 4>>)
      assert {:error, {:invalid_key_size, 4}} = Keys.decode_public_key(short_key)
    end
  end

  describe "save/2 and load/1" do
    setup do
      path = Path.join(System.tmp_dir!(), "burrow_test_key_#{:rand.uniform(1_000_000)}.key")
      on_exit(fn -> File.rm(path) end)
      {:ok, path: path}
    end

    test "saves and loads keypair", %{path: path} do
      {:ok, original} = Keys.generate()

      assert :ok = Keys.save(original, path)
      assert {:ok, loaded} = Keys.load(path)

      assert loaded.public == original.public
      assert loaded.private == original.private
    end

    test "saved file has restricted permissions", %{path: path} do
      {:ok, keypair} = Keys.generate()
      :ok = Keys.save(keypair, path)

      {:ok, stat} = File.stat(path)
      # Owner read/write only (0o600)
      assert stat.mode == 0o100600
    end

    test "load returns error for missing file" do
      assert {:error, :enoent} = Keys.load("/nonexistent/path/key.key")
    end

    test "load returns error for invalid format", %{path: path} do
      File.write!(path, "invalid content")
      assert {:error, :invalid_header} = Keys.load(path)
    end
  end

  describe "valid?/1" do
    test "returns true for valid keypair" do
      {:ok, keypair} = Keys.generate()
      assert Keys.valid?(keypair)
    end

    test "returns false for invalid keypair" do
      refute Keys.valid?(%{public: <<1, 2, 3>>, private: <<1, 2, 3>>})
      refute Keys.valid?(%{})
      refute Keys.valid?(nil)
    end
  end
end
