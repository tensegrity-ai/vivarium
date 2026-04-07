defmodule Keeper do
  @moduledoc "Top-level API for managing terrariums."

  alias Keeper.{Terrarium, Config, Git}

  def create(name, opts \\ []) do
    config = Config.new(opts)

    with {:ok, _pid} <- start_terrarium(name, config) do
      Terrarium.create(name)
    end
  end

  def wake(name, message, opts \\ []) do
    Terrarium.wake(name, message, opts)
  end

  def checkpoint(name) do
    Terrarium.checkpoint(name)
  end

  def snapshot(name) do
    Terrarium.snapshot(name)
  end

  def history(name, opts \\ []) do
    Git.log(name, opts)
  end

  def diff(name, from_ref, to_ref) do
    Git.diff(name, from_ref, to_ref)
  end

  def status(name) do
    Terrarium.status(name)
  end

  defp start_terrarium(name, config) do
    DynamicSupervisor.start_child(
      Keeper.TerrariumSupervisor,
      {Terrarium, {name, config}}
    )
  end
end
