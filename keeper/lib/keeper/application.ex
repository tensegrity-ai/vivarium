defmodule Keeper.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Keeper.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Keeper.TerrariumSupervisor}
    ]

    opts = [strategy: :one_for_one, name: Keeper.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
