defmodule Keeper.Terrarium do
  @moduledoc "GenServer managing a single terrarium's lifecycle."
  use GenServer

  alias Keeper.{Sprites, Seed, Wake}

  @max_continuations 5

  defstruct [
    :name,
    status: :idle,
    breath_count: 0,
    checkpoint_history: [],
    consecutive_continuations: 0,
    crash_recovery: false
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

  def handle_call({:wake, message, opts}, _from, state) do
    state = %{state | status: :breathing}

    # If previous breath crashed, flag this wake as crash recovery
    opts =
      if state.crash_recovery do
        Keyword.put(opts, :inbox_type, :crash_recovery)
      else
        opts
      end

    case breathe_loop(state, message, opts) do
      {:ok, outbox, state} ->
        {:reply, {:ok, outbox}, %{state | status: :idle}}

      {:runaway, state} ->
        {:reply, {:error, :runaway}, %{state | status: :idle}}

      {:error, reason, state} ->
        {:reply, {:error, reason}, %{state | status: :idle}}
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

  # -- Breath loop with continuation support --

  defp breathe_loop(state, message, opts) do
    case Wake.breathe(state.name, message, opts) do
      {:ok, %{type: :continuing}} ->
        state = %{
          state
          | breath_count: state.breath_count + 1,
            consecutive_continuations: state.consecutive_continuations + 1,
            crash_recovery: false
        }

        # Checkpoint between continuation breaths
        do_checkpoint(state)

        if state.consecutive_continuations >= @max_continuations do
          {:runaway, state}
        else
          # Re-wake with continuation inbox
          breathe_loop(state, "Continuation", Keyword.put(opts, :inbox_type, :continuation))
        end

      {:ok, outbox} ->
        state = %{
          state
          | breath_count: state.breath_count + 1,
            consecutive_continuations: 0,
            crash_recovery: false
        }

        {:ok, outbox, state}

      {:error, {:crash, reason}} ->
        # Bootstrap crashed — checkpoint whatever exists, flag next wake
        do_checkpoint(state)
        state = %{state | crash_recovery: true}
        {:error, {:crash, reason}, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp do_checkpoint(%{name: name} = _state) do
    # Best-effort checkpoint between continuations — don't fail the loop
    Sprites.checkpoint(name)
  end

  # -- Registry --

  defp via(name), do: {:via, Registry, {Keeper.Registry, name}}
end
