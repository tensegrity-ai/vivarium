defmodule Keeper do
  @moduledoc "Top-level API for managing terrariums."

  alias Keeper.Terrarium

  def create(name) do
    with {:ok, _pid} <- start_terrarium(name) do
      Terrarium.create(name)
    end
  end

  def wake(name, message, opts \\ []) do
    Terrarium.wake(name, message, opts)
  end

  def checkpoint(name) do
    Terrarium.checkpoint(name)
  end

  def status(name) do
    Terrarium.status(name)
  end

  defp start_terrarium(name) do
    DynamicSupervisor.start_child(
      Keeper.TerrariumSupervisor,
      {Terrarium, name}
    )
  end
end
