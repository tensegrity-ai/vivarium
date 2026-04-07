defmodule Keeper.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        {Registry, keys: :unique, name: Keeper.Registry},
        {DynamicSupervisor, strategy: :one_for_one, name: Keeper.TerrariumSupervisor},
        {Task.Supervisor, name: Keeper.TaskSupervisor}
      ] ++ telegram_child()

    opts = [strategy: :one_for_one, name: Keeper.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp telegram_child do
    case System.get_env("TELEGRAM_BOT_TOKEN") do
      nil -> []
      token -> [{Keeper.Telegram, token: token}]
    end
  end
end
