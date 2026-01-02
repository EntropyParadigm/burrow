defmodule Burrow.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Registry for tracking tunnels
      {Registry, keys: :unique, name: Burrow.TunnelRegistry},

      # DynamicSupervisor for tunnel processes
      {DynamicSupervisor, strategy: :one_for_one, name: Burrow.TunnelSupervisor},

      # Metrics collector
      Burrow.Metrics
    ]

    opts = [strategy: :one_for_one, name: Burrow.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
