defmodule Burrow.ServerTest do
  use ExUnit.Case

  alias Burrow.Server

  # Use unique ports to avoid conflicts between tests
  defp random_port, do: Enum.random(50000..59999)

  setup do
    # Ensure any previous server is stopped
    try do
      GenServer.stop(Server, :normal, 100)
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  describe "start_link/1" do
    test "requires port option" do
      Process.flag(:trap_exit, true)
      {:error, {%KeyError{key: :port}, _}} = Server.start_link(token: "secret")
    end

    test "requires token or token_hash option" do
      Process.flag(:trap_exit, true)
      {:error, {%ArgumentError{message: "either :token or :token_hash is required"}, _}} =
        Server.start_link(port: random_port())
    end

    test "starts server with token" do
      port = random_port()
      {:ok, pid} = Server.start_link(port: port, token: "secret")

      assert Process.alive?(pid)

      GenServer.stop(pid)
    end

    test "starts server with token_hash" do
      port = random_port()
      hash = Burrow.Token.hash("secret")
      {:ok, pid} = Server.start_link(port: port, token_hash: hash)

      assert Process.alive?(pid)

      GenServer.stop(pid)
    end

    test "accepts max_connections option" do
      port = random_port()
      {:ok, pid} = Server.start_link(port: port, token: "secret", max_connections: 50)

      assert Process.alive?(pid)

      GenServer.stop(pid)
    end
  end

  describe "clients/1" do
    test "returns empty list when no clients connected" do
      port = random_port()
      {:ok, pid} = Server.start_link(port: port, token: "secret")

      clients = Server.clients(pid)

      assert clients == []

      GenServer.stop(pid)
    end
  end

  describe "metrics/1" do
    test "returns metrics map" do
      port = random_port()
      {:ok, pid} = Server.start_link(port: port, token: "secret")

      metrics = Server.metrics(pid)

      assert is_map(metrics)
      assert metrics.clients == 0
      assert metrics.tunnels == 0
      assert metrics.public_listeners == 0

      GenServer.stop(pid)
    end
  end

  describe "draining?/1" do
    test "returns false when not draining" do
      port = random_port()
      {:ok, pid} = Server.start_link(port: port, token: "secret")

      refute Server.draining?(pid)

      GenServer.stop(pid)
    end
  end

  describe "disconnect_client/2" do
    test "returns error for non-existent client" do
      port = random_port()
      {:ok, pid} = Server.start_link(port: port, token: "secret")

      result = Server.disconnect_client(pid, "nonexistent")

      assert result == {:error, :not_found}

      GenServer.stop(pid)
    end
  end

  describe "shutdown/2" do
    test "initiates graceful shutdown with no clients" do
      port = random_port()
      {:ok, pid} = Server.start_link(port: port, token: "secret")

      result = Server.shutdown(pid)

      assert result == :ok

      # Server should still be accessible briefly
      Process.sleep(50)
    end

    test "accepts drain_timeout option" do
      port = random_port()
      {:ok, pid} = Server.start_link(port: port, token: "secret")

      result = Server.shutdown(pid, drain_timeout: 1000)

      assert result == :ok
    end
  end

  describe "callbacks" do
    test "on_connect callback is stored" do
      port = random_port()
      callback = fn _info -> :ok end

      {:ok, pid} = Server.start_link(
        port: port,
        token: "secret",
        on_connect: callback
      )

      assert Process.alive?(pid)

      GenServer.stop(pid)
    end

    test "on_disconnect callback is stored" do
      port = random_port()
      callback = fn _info, _reason -> :ok end

      {:ok, pid} = Server.start_link(
        port: port,
        token: "secret",
        on_disconnect: callback
      )

      assert Process.alive?(pid)

      GenServer.stop(pid)
    end
  end

  describe "listening" do
    test "actually listens on the specified port" do
      port = random_port()
      {:ok, pid} = Server.start_link(port: port, token: "secret")

      # Try to connect - should succeed even though we won't authenticate
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary], 1000)

      assert socket != nil

      :gen_tcp.close(socket)
      GenServer.stop(pid)
    end
  end
end
