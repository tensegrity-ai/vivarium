defmodule Keeper.Terrarium do
  @moduledoc "GenServer managing a single terrarium's lifecycle."
  use GenServer

  alias Keeper.{Sprites, Seed, Wake}

  defstruct [
    :name,
    status: :idle,
    breath_count: 0,
    checkpoint_history: [],
    consecutive_continuations: 0
  ]

  # -- Client API --

  def start_link(name) do
    GenServer.start_link(__MODULE__, name, name: via(name))
  end

  def create(name) do
    GenServer.call(via(name), :create, :infinity)
  end

  def wake(name, message, opts \\ []) do
    GenServer.call(via(name), {:wake, message, opts}, :infinity)
  end

  def checkpoint(name) do
    GenServer.call(via(name), :checkpoint, 60_000)
  end

  def status(name) do
    GenServer.call(via(name), :status)
  end

  # -- Server callbacks --

  @impl true
  def init(name) do
    {:ok, %__MODULE__{name: name}}
  end

  @impl true
  def handle_call(:create, _from, %{name: name} = state) do
    case Seed.create(name) do
      {:ok, _} -> {:reply, :ok, %{state | status: :idle}}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:wake, message, opts}, _from, %{name: name} = state) do
    state = %{state | status: :breathing}

    case Wake.breathe(name, message, opts) do
      {:ok, outbox} ->
        state = %{state | status: :idle, breath_count: state.breath_count + 1}

        {:reply, {:ok, outbox}, state}

      error ->
        {:reply, error, %{state | status: :idle}}
    end
  end

  def handle_call(:checkpoint, _from, %{name: name} = state) do
    case Sprites.checkpoint(name) do
      {:ok, output} ->
        entry = %{
          output: output,
          breath: state.breath_count,
          timestamp: DateTime.utc_now()
        }

        state = %{state | checkpoint_history: [entry | state.checkpoint_history]}
        {:reply, {:ok, output}, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call(:status, _from, state) do
    {:reply, state, state}
  end

  # -- Registry --

  defp via(name), do: {:via, Registry, {Keeper.Registry, name}}
end
