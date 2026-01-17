defmodule Burrow.ClientTest do
  use ExUnit.Case

  alias Burrow.Client

  describe "start_link/1" do
    test "requires host option" do
      Process.flag(:trap_exit, true)
      {:error, {%KeyError{key: :host}, _}} = Client.start_link(port: 4000, token: "secret", tunnels: [])
    end

    test "requires port option" do
      Process.flag(:trap_exit, true)
      {:error, {%KeyError{key: :port}, _}} = Client.start_link(host: "localhost", token: "secret", tunnels: [])
    end

    test "requires token option" do
      Process.flag(:trap_exit, true)
      {:error, {%KeyError{key: :token}, _}} = Client.start_link(host: "localhost", port: 4000, tunnels: [])
    end

    test "requires tunnels option" do
      Process.flag(:trap_exit, true)
      {:error, {%KeyError{key: :tunnels}, _}} = Client.start_link(host: "localhost", port: 4000, token: "secret")
    end

    test "starts client process with valid options" do
      # Client will try to connect and fail, but the process should start
      {:ok, pid} = Client.start_link(
        host: "127.0.0.1",
        port: 59999,  # Unlikely to be in use
        token: "secret",
        tunnels: [[name: "test", local: 8080, remote: 80]],
        reconnect: false  # Don't keep retrying
      )

      assert Process.alive?(pid)

      # Clean up
      Process.exit(pid, :normal)
    end
  end

  describe "status/1" do
    test "returns status map" do
      {:ok, pid} = Client.start_link(
        host: "127.0.0.1",
        port: 59999,
        token: "secret",
        tunnels: [[name: "test", local: 8080, remote: 80]],
        reconnect: false
      )

      # Give it a moment to attempt connection
      Process.sleep(50)

      status = Client.status(pid)

      assert is_map(status)
      assert Map.has_key?(status, :connected)
      assert Map.has_key?(status, :server)
      assert Map.has_key?(status, :tunnels)
      assert status.server == "127.0.0.1:59999"

      Process.exit(pid, :normal)
    end
  end

  describe "disconnect/1" do
    test "disconnects and disables reconnect" do
      {:ok, pid} = Client.start_link(
        host: "127.0.0.1",
        port: 59999,
        token: "secret",
        tunnels: [[name: "test", local: 8080, remote: 80]],
        reconnect: true
      )

      assert :ok = Client.disconnect(pid)

      # Process should still be alive but disconnected
      assert Process.alive?(pid)

      Process.exit(pid, :normal)
    end
  end

  describe "tunnel configuration" do
    test "normalizes tunnel configs with names" do
      {:ok, pid} = Client.start_link(
        host: "127.0.0.1",
        port: 59999,
        token: "secret",
        tunnels: [
          [name: "web", local: 8080, remote: 80],
          [name: "ssh", local: 22, remote: 2222]
        ],
        reconnect: false
      )

      Process.sleep(50)
      _status = Client.status(pid)

      # Tunnels won't be active since we can't connect,
      # but the process should have accepted the config
      assert Process.alive?(pid)

      Process.exit(pid, :normal)
    end

    test "auto-generates tunnel names when not provided" do
      {:ok, pid} = Client.start_link(
        host: "127.0.0.1",
        port: 59999,
        token: "secret",
        tunnels: [
          [local: 8080, remote: 80],
          [local: 3000, remote: 3000]
        ],
        reconnect: false
      )

      assert Process.alive?(pid)

      Process.exit(pid, :normal)
    end
  end

  describe "TLS configuration" do
    test "accepts tls option" do
      {:ok, pid} = Client.start_link(
        host: "127.0.0.1",
        port: 59999,
        token: "secret",
        tunnels: [[local: 8080, remote: 80]],
        tls: true,
        reconnect: false
      )

      assert Process.alive?(pid)

      Process.exit(pid, :normal)
    end

    test "accepts tls_verify option" do
      {:ok, pid} = Client.start_link(
        host: "127.0.0.1",
        port: 59999,
        token: "secret",
        tunnels: [[local: 8080, remote: 80]],
        tls: true,
        tls_verify: :verify_none,
        reconnect: false
      )

      assert Process.alive?(pid)

      Process.exit(pid, :normal)
    end
  end

  describe "reconnection settings" do
    test "accepts custom reconnect_interval" do
      {:ok, pid} = Client.start_link(
        host: "127.0.0.1",
        port: 59999,
        token: "secret",
        tunnels: [[local: 8080, remote: 80]],
        reconnect: true,
        reconnect_interval: 1000,
        max_reconnect_interval: 5000
      )

      assert Process.alive?(pid)

      Process.exit(pid, :normal)
    end

    test "accepts custom heartbeat settings" do
      {:ok, pid} = Client.start_link(
        host: "127.0.0.1",
        port: 59999,
        token: "secret",
        tunnels: [[local: 8080, remote: 80]],
        heartbeat_interval: 15_000,
        heartbeat_timeout: 45_000,
        reconnect: false
      )

      assert Process.alive?(pid)

      Process.exit(pid, :normal)
    end
  end
end
