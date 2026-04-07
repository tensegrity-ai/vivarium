defmodule Keeper.Terrarium do
  @moduledoc "GenServer managing a single terrarium's lifecycle."
  use GenServer

  require Logger

  alias Keeper.{Sprites, Seed, Wake, Budget, Config, Git}

  @max_continuations 5

  defstruct [
    :name,
    :config,
    :budget,
    :last_breath_at,
    status: :idle,
    breath_count: 0,
    consecutive_continuations: 0,
    crash_recovery: false,
    scheduled_wakes: []
  ]

  # -- Client API --

  def start_link({name, config}) do
    GenServer.start_link(__MODULE__, {name, config}, name: via(name))
  end

  def start_link(name) do
    start_link({name, Config.new()})
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

  def snapshot(name) do
    GenServer.call(via(name), :snapshot, 120_000)
  end

  def status(name) do
    GenServer.call(via(name), :status)
  end

  # -- Server callbacks --

  @impl true
  def init({name, config}) do
    state = %__MODULE__{name: name, config: config, budget: Budget.new()}
    state = maybe_schedule_heartbeat(state)
    {:ok, state}
  end

  def init(name), do: init({name, Config.new()})

  @impl true
  def handle_call(:create, _from, %{name: name, config: config} = state) do
    case Seed.create(name, config) do
      {:ok, _} -> {:reply, :ok, %{state | status: :idle}}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:wake, message, opts}, _from, state) do
    state = %{state | status: :breathing, budget: Budget.maybe_reset(state.budget)}

    # If previous breath crashed, flag this wake as crash recovery
    opts =
      if state.crash_recovery do
        Keyword.put(opts, :inbox_type, :crash_recovery)
      else
        opts
      end

    opts = inject_budget_opts(opts, state)

    case breathe_loop(state, message, opts) do
      {:ok, outbox, state} ->
        state = handle_outbox_requests(state, outbox)
        {:reply, {:ok, outbox}, %{state | status: :idle}}

      {:runaway, state} ->
        {:reply, {:error, :runaway}, %{state | status: :idle}}

      {:error, reason, state} ->
        {:reply, {:error, reason}, %{state | status: :idle}}
    end
  end

  def handle_call({:checkpoint, attrs}, _from, state) do
    case do_git_commit(state, attrs) do
      {:ok, meta} -> {:reply, {:ok, meta}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call(:checkpoint, _from, state) do
    case do_git_commit(state, trigger: :message) do
      {:ok, meta} -> {:reply, {:ok, meta}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call(:snapshot, _from, %{name: name} = state) do
    case Sprites.checkpoint(name) do
      {:ok, result} -> {:reply, {:ok, result}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call(:status, _from, state) do
    {:reply, state, state}
  end

  # -- Heartbeat and scheduled wakes --

  @min_heartbeat_gap_ms :timer.seconds(60)

  @impl true
  def handle_info(:heartbeat, state) do
    state = %{state | budget: Budget.maybe_reset(state.budget)}
    state = maybe_schedule_heartbeat(state)

    cond do
      too_soon_after_breath?(state) ->
        Logger.debug("[#{state.name}] heartbeat skipped — breath completed recently")
        {:noreply, state}

      Budget.exhausted?(state.budget, state.config.budget) ->
        Logger.info("[#{state.name}] heartbeat deferred — budget exhausted")
        {:noreply, state}

      true ->
        Logger.info("[#{state.name}] heartbeat wake")
        state = %{state | status: :breathing}

        opts =
          inject_budget_opts([inbox_type: :heartbeat, from: "system", channel: "cron"], state)

        case breathe_loop(
               state,
               "No one is asking you for anything right now. You have a full breath.",
               opts
             ) do
          {:ok, outbox, state} ->
            state = handle_outbox_requests(state, outbox)
            {:noreply, %{state | status: :idle}}

          {:runaway, state} ->
            Logger.warning("[#{state.name}] heartbeat runaway detected")
            {:noreply, %{state | status: :idle}}

          {:error, reason, state} ->
            Logger.error("[#{state.name}] heartbeat error: #{inspect(reason)}")
            {:noreply, %{state | status: :idle}}
        end
    end
  end

  def handle_info({:scheduled_wake, prompt}, state) do
    state = %{state | budget: Budget.maybe_reset(state.budget)}

    if Budget.exhausted?(state.budget, state.config.budget) do
      Logger.info("[#{state.name}] scheduled wake deferred — budget exhausted")
      {:noreply, state}
    else
      Logger.info("[#{state.name}] scheduled wake: #{String.slice(prompt, 0..60)}")
      state = %{state | status: :breathing}

      opts =
        inject_budget_opts(
          [inbox_type: :scheduled, from: "system", channel: "scheduled"],
          state
        )

      case breathe_loop(state, prompt, opts) do
        {:ok, outbox, state} ->
          state = handle_outbox_requests(state, outbox)
          {:noreply, %{state | status: :idle}}

        {:runaway, state} ->
          Logger.warning("[#{state.name}] scheduled wake runaway")
          {:noreply, %{state | status: :idle}}

        {:error, reason, state} ->
          Logger.error("[#{state.name}] scheduled wake error: #{inspect(reason)}")
          {:noreply, %{state | status: :idle}}
      end
    end
  end

  # -- Breath loop with continuation support --

  defp breathe_loop(state, message, opts) do
    case Wake.breathe(state.name, message, opts) do
      {:ok, %{type: :continuing} = outbox} ->
        state = record_breath(state, outbox)
        state = %{state | consecutive_continuations: state.consecutive_continuations + 1}

        checkpoint_attrs = [
          trigger: :continuation,
          breath_number: state.breath_count,
          tokens_used: outbox |> Map.get(:usage, %{}) |> Map.get("total_tokens", 0),
          compute_ms: Map.get(outbox, :compute_ms, 0),
          outbox_type: :continuing,
          outbox_summary: extract_summary(outbox)
        ]

        case do_git_commit(state, checkpoint_attrs) do
          {:ok, _meta} ->
            if state.consecutive_continuations >= @max_continuations do
              {:runaway, state}
            else
              opts = Keyword.put(opts, :inbox_type, :continuation)
              breathe_loop(state, "Continuation", opts)
            end

          {:error, _} = err ->
            # Checkpoint failed but breath succeeded — continue anyway
            Logger.warning("[#{state.name}] continuation checkpoint failed: #{inspect(err)}")

            if state.consecutive_continuations >= @max_continuations do
              {:runaway, state}
            else
              opts = Keyword.put(opts, :inbox_type, :continuation)
              breathe_loop(state, "Continuation", opts)
            end
        end

      {:ok, outbox} ->
        state = record_breath(state, outbox)
        state = %{state | consecutive_continuations: 0}

        trigger = Keyword.get(opts, :inbox_type, :message)

        checkpoint_attrs = [
          trigger: trigger,
          breath_number: state.breath_count,
          tokens_used: outbox |> Map.get(:usage, %{}) |> Map.get("total_tokens", 0),
          compute_ms: Map.get(outbox, :compute_ms, 0),
          outbox_type: Map.get(outbox, :type),
          outbox_summary: extract_summary(outbox)
        ]

        state =
          case do_git_commit(state, checkpoint_attrs) do
            {:ok, _meta} -> state
            _ -> state
          end

        {:ok, outbox, state}

      {:error, {:crash, reason, %{usage: usage, compute_ms: compute_ms}}} ->
        crash_attrs = [
          trigger: :crash,
          breath_number: state.breath_count,
          tokens_used: Map.get(usage, "total_tokens", 0),
          compute_ms: compute_ms
        ]

        state =
          case do_git_commit(state, crash_attrs) do
            {:ok, _meta} -> state
            _ -> state
          end

        tokens = Map.get(usage, "total_tokens", 0)
        budget = Budget.record(state.budget, tokens, compute_ms)
        state = %{state | crash_recovery: true, budget: budget}
        {:error, {:crash, reason}, state}

      {:error, {:crash, reason}} ->
        state =
          case do_git_commit(state, trigger: :crash, breath_number: state.breath_count) do
            {:ok, _meta} -> state
            _ -> state
          end

        state = %{state | crash_recovery: true}
        {:error, {:crash, reason}, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp record_breath(state, outbox) do
    tokens = outbox |> Map.get(:usage, %{}) |> Map.get("total_tokens", 0)
    compute_ms = Map.get(outbox, :compute_ms, 0)
    budget = Budget.record(state.budget, tokens, compute_ms)

    %{
      state
      | breath_count: state.breath_count + 1,
        crash_recovery: false,
        budget: budget,
        last_breath_at: System.monotonic_time(:millisecond)
    }
  end

  defp do_git_commit(state, attrs) do
    attrs = Keyword.put_new(attrs, :breath_number, state.breath_count)
    Git.commit(state.name, attrs)
  end

  # -- Budget --

  defp inject_budget_opts(opts, state) do
    opts
    |> Keyword.put(:budget, state.budget)
    |> Keyword.put(:budget_limits, state.config.budget)
  end

  # -- Heartbeat scheduling --

  defp maybe_schedule_heartbeat(%{config: %{heartbeat_interval_ms: nil}} = state), do: state

  defp maybe_schedule_heartbeat(%{config: %{heartbeat_interval_ms: ms}} = state) do
    Process.send_after(self(), :heartbeat, ms)
    state
  end

  # -- Outbox request handling --

  defp handle_outbox_requests(state, %{raw: raw}) do
    case YamlElixir.read_from_string(raw) do
      {:ok, %{"requests" => requests}} when is_list(requests) ->
        Enum.reduce(requests, state, &handle_request/2)

      _ ->
        state
    end
  end

  defp handle_request(%{"type" => "schedule", "when" => when_str, "prompt" => prompt}, state) do
    case DateTime.from_iso8601(when_str) do
      {:ok, target, _} ->
        delay_ms = max(DateTime.diff(target, DateTime.utc_now(), :millisecond), 0)
        Process.send_after(self(), {:scheduled_wake, prompt}, delay_ms)

        Logger.info(
          "[#{state.name}] scheduled wake at #{when_str}: #{String.slice(prompt, 0..60)}"
        )

        state

      _ ->
        Logger.warning(
          "[#{state.name}] ignoring schedule request with bad timestamp: #{when_str}"
        )

        state
    end
  end

  defp handle_request(%{"type" => "credential", "service" => service} = req, state) do
    reason = Map.get(req, "reason", "(no reason given)")

    Logger.info("[#{state.name}] credential request: #{service} — #{reason}")

    # For now, just log it. Sprint 3+ will route to human for approval.
    state
  end

  defp handle_request(req, state) do
    Logger.debug("[#{state.name}] ignoring unknown request: #{inspect(req)}")
    state
  end

  defp too_soon_after_breath?(%{last_breath_at: nil}), do: false

  defp too_soon_after_breath?(%{last_breath_at: last}) do
    System.monotonic_time(:millisecond) - last < @min_heartbeat_gap_ms
  end

  # -- Helpers --

  defp extract_summary(%{raw: raw}) do
    case YamlElixir.read_from_string(raw) do
      {:ok, %{"content" => content}} when is_binary(content) ->
        content |> String.split("\n") |> hd() |> String.slice(0..120)

      _ ->
        nil
    end
  end

  defp extract_summary(_), do: nil

  # -- Registry --

  def via(name), do: {:via, Registry, {Keeper.Registry, name}}
end
