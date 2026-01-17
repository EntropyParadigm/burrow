defmodule BurrowTest do
  use ExUnit.Case

  describe "version/0" do
    test "returns version string" do
      version = Burrow.version()

      assert is_binary(version)
      assert version == "0.1.0"
    end
  end

  describe "connect/2" do
    test "parses host:port format" do
      # This will fail to connect but should parse the server string correctly
      {:ok, pid} = Burrow.connect("127.0.0.1:59999",
        token: "secret",
        tunnels: [[local: 8080, remote: 80]],
        reconnect: false
      )

      status = Burrow.Client.status(pid)
      assert status.server == "127.0.0.1:59999"

      Process.exit(pid, :normal)
    end

    test "defaults to port 4000 when not specified" do
      {:ok, pid} = Burrow.connect("127.0.0.1",
        token: "secret",
        tunnels: [[local: 8080, remote: 80]],
        reconnect: false
      )

      status = Burrow.Client.status(pid)
      assert status.server == "127.0.0.1:4000"

      Process.exit(pid, :normal)
    end

    test "requires token option" do
      Process.flag(:trap_exit, true)
      {:error, {%KeyError{key: :token}, _}} =
        Burrow.connect("127.0.0.1:4000", tunnels: [[local: 8080, remote: 80]])
    end

    test "requires tunnels option" do
      Process.flag(:trap_exit, true)
      {:error, {%KeyError{key: :tunnels}, _}} =
        Burrow.connect("127.0.0.1:4000", token: "secret")
    end
  end

  describe "listen/2" do
    test "starts a server on the specified port" do
      port = Enum.random(50000..59999)
      {:ok, pid} = Burrow.listen(port, token: "secret")

      assert Process.alive?(pid)

      # Verify it's actually listening
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary], 1000)
      :gen_tcp.close(socket)

      GenServer.stop(pid)
    end

    test "requires token option" do
      Process.flag(:trap_exit, true)
      {:error, {%ArgumentError{}, _}} = Burrow.listen(59999, [])
    end
  end
end
