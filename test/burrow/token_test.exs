defmodule Burrow.TokenTest do
  use ExUnit.Case, async: true

  alias Burrow.Token

  describe "generate/1" do
    test "generates a token with default settings" do
      token = Token.generate()

      assert is_binary(token)
      # Default is 32 bytes base64 encoded (without padding)
      # 32 bytes = 43 chars in base64 url-safe without padding
      assert byte_size(token) > 20
    end

    test "generates unique tokens" do
      tokens = for _ <- 1..100, do: Token.generate()
      unique_tokens = Enum.uniq(tokens)

      assert length(unique_tokens) == 100
    end

    test "respects length option" do
      token = Token.generate(length: 16)

      # 16 bytes base64 encoded = ~22 chars
      assert is_binary(token)
      assert byte_size(token) > 10
    end

    test "supports hex encoding" do
      token = Token.generate(length: 16, encoding: :hex)

      # 16 bytes in hex = 32 chars
      assert String.length(token) == 32
      assert Regex.match?(~r/^[0-9a-f]+$/, token)
    end

    test "supports base64 encoding" do
      token = Token.generate(length: 16, encoding: :base64)

      assert is_binary(token)
      # Base64 url-safe characters
      assert Regex.match?(~r/^[A-Za-z0-9_-]+$/, token)
    end

    test "defaults to base64 for unknown encoding" do
      token = Token.generate(encoding: :unknown)

      assert is_binary(token)
      assert Regex.match?(~r/^[A-Za-z0-9_-]+$/, token)
    end
  end

  describe "hash/1" do
    test "returns an Argon2id hash" do
      hash = Token.hash("mysecret")

      assert String.starts_with?(hash, "$argon2id$")
    end

    test "generates different hashes for same input (due to salt)" do
      hash1 = Token.hash("mysecret")
      hash2 = Token.hash("mysecret")

      refute hash1 == hash2
    end

    test "hash includes version and parameters" do
      hash = Token.hash("test")

      # Should contain version v=19 and memory/time/parallelism params
      assert String.contains?(hash, "v=19")
      assert String.contains?(hash, "m=")
      assert String.contains?(hash, "t=")
      assert String.contains?(hash, "p=")
    end
  end

  describe "verify?/2" do
    test "returns true for correct token" do
      token = "my_secret_token"
      hash = Token.hash(token)

      assert Token.verify?(token, hash) == true
    end

    test "returns false for incorrect token" do
      token = "my_secret_token"
      hash = Token.hash(token)

      refute Token.verify?("wrong_token", hash)
    end

    test "returns false for empty token against valid hash" do
      hash = Token.hash("secret")

      refute Token.verify?("", hash)
    end

    test "handles unicode tokens" do
      token = "tökèn_with_üñîçödé_🔐"
      hash = Token.hash(token)

      assert Token.verify?(token, hash) == true
      refute Token.verify?("wrong", hash)
    end

    test "timing is constant regardless of input" do
      hash = Token.hash("secret")

      # Verify both correct and incorrect tokens complete
      # (we can't easily test constant-time, but we verify it works)
      assert Token.verify?("secret", hash) == true
      refute Token.verify?("s", hash)
      refute Token.verify?("secretsecretsecretsecret", hash)
    end
  end

  describe "hash?/1" do
    test "returns true for Argon2id hash" do
      hash = Token.hash("test")

      assert Token.hash?(hash) == true
    end

    test "returns true for any argon2 variant" do
      assert Token.hash?("$argon2id$v=19$m=65536,t=3,p=4$salt$hash") == true
      assert Token.hash?("$argon2i$v=19$m=65536,t=3,p=4$salt$hash") == true
      assert Token.hash?("$argon2d$v=19$m=65536,t=3,p=4$salt$hash") == true
    end

    test "returns false for plaintext token" do
      refute Token.hash?("plaintext_token")
    end

    test "returns false for other hash types" do
      refute Token.hash?("$2b$12$salt.hash")  # bcrypt
      refute Token.hash?("$sha256$hash")
    end

    test "returns false for nil" do
      refute Token.hash?(nil)
    end

    test "returns false for non-binary values" do
      refute Token.hash?(123)
      refute Token.hash?(:atom)
      refute Token.hash?([])
    end
  end

  describe "integration" do
    test "generate -> hash -> verify workflow" do
      # Generate a random token
      token = Token.generate()

      # Hash it for storage
      hash = Token.hash(token)

      # Verify it matches
      assert Token.verify?(token, hash)

      # Verify wrong tokens don't match
      wrong_token = Token.generate()
      refute Token.verify?(wrong_token, hash)
    end
  end
end
