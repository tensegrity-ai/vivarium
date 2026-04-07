defmodule Keeper.Wake do
  @moduledoc "Executes one breath cycle: write inbox, run bootstrap, read outbox."

  alias Keeper.{Sprites, Budget}

  @doc """
  Execute one breath. Returns {:ok, %{type: atom, raw: string, usage: map, compute_ms: integer}}
  or {:error, {:crash, reason}}.

  The type is one of :response, :continuing, :request, :silent.
  Usage contains token counts from the bootstrap. compute_ms is wall-clock time.
  """
  def breathe(name, message, opts \\ []) do
    api_key = Keyword.get(opts, :api_key, System.get_env("ANTHROPIC_API_KEY"))
    budget = Keyword.get(opts, :budget)
    budget_limits = Keyword.get(opts, :budget_limits)
    inbox_yaml = build_inbox(message, opts)
    unix_ts = System.os_time(:second)

    with {:ok, _} <- clear_inbox(name),
         {:ok, _} <- clear_outbox(name),
         :ok <- maybe_write_budget_status(name, budget, budget_limits),
         {:ok, _} <- Sprites.write_file(name, "/vivarium/inbox/#{unix_ts}.msg", inbox_yaml),
         {compute_ms, {:ok, _}} <- run_bootstrap(name, api_key) do
      case read_and_parse_outbox(name) do
        {:ok, outbox} ->
          usage = read_usage(name)
          {:ok, Map.merge(outbox, %{usage: usage, compute_ms: compute_ms})}

        error ->
          error
      end
    else
      {compute_ms, {:error, reason}} ->
        usage = read_usage(name)
        {:error, {:crash, reason, %{usage: usage, compute_ms: compute_ms}}}

      {:error, reason} ->
        {:error, {:crash, reason}}
    end
  end

  @doc "Build a continuation inbox message for re-wake."
  def continuation_inbox do
    ts = DateTime.utc_now() |> DateTime.to_iso8601()

    """
    type: continuation
    timestamp: "#{ts}"
    from: system
    channel: internal
    content: "Continuation — pick up from your handoff."
    context:
      continuation: true
    """
  end

  @doc "Build a crash recovery inbox message."
  def crash_recovery_inbox(message) do
    ts = DateTime.utc_now() |> DateTime.to_iso8601()

    """
    type: message
    timestamp: "#{ts}"
    from: system
    channel: internal
    content: |
      #{indent(message, 2)}
    context:
      crash_recovery: true
    """
  end

  defp build_inbox(message, opts) do
    from = Keyword.get(opts, :from, "human")
    channel = Keyword.get(opts, :channel, "cli")
    ts = DateTime.utc_now() |> DateTime.to_iso8601()

    case Keyword.get(opts, :inbox_type) do
      :continuation ->
        continuation_inbox()

      :crash_recovery ->
        crash_recovery_inbox(message)

      :heartbeat ->
        """
        type: heartbeat
        timestamp: "#{ts}"
        from: system
        channel: cron
        content: |
          #{indent(message, 2)}
        """

      :scheduled ->
        """
        type: scheduled
        timestamp: "#{ts}"
        from: system
        channel: scheduled
        content: |
          #{indent(message, 2)}
        """

      _ ->
        """
        type: message
        timestamp: "#{ts}"
        from: #{from}
        channel: #{channel}
        content: |
          #{indent(message, 2)}
        """
    end
  end

  defp clear_inbox(name) do
    Sprites.exec(name, "rm -f /vivarium/inbox/*.msg")
  end

  defp clear_outbox(name) do
    Sprites.exec(name, "rm -f /vivarium/outbox/*.msg")
  end

  defp run_bootstrap(name, api_key) do
    start = System.monotonic_time(:millisecond)

    result =
      Sprites.exec(
        name,
        "python3 /vivarium/bootstrap/bootstrap.py",
        env: [{"ANTHROPIC_API_KEY", api_key}]
      )

    elapsed = System.monotonic_time(:millisecond) - start
    {elapsed, result}
  end

  defp maybe_write_budget_status(_name, nil, _limits), do: :ok
  defp maybe_write_budget_status(_name, _budget, nil), do: :ok

  defp maybe_write_budget_status(name, budget, limits) do
    yaml = Budget.to_yaml(budget, limits)

    case Sprites.write_file(name, "/vivarium/.keeper/budget_status", yaml) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp read_usage(name) do
    case Sprites.read_file(name, "/vivarium/.keeper/breath_usage.yaml") do
      {:ok, raw} ->
        case YamlElixir.read_from_string(raw) do
          {:ok, data} -> data
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp read_and_parse_outbox(name) do
    case Sprites.exec(name, "ls -t /vivarium/outbox/*.msg 2>/dev/null | head -1") do
      {:ok, ""} ->
        {:ok, %{type: :response, raw: "(no outbox message)"}}

      {:ok, path} ->
        case Sprites.read_file(name, String.trim(path)) do
          {:ok, raw} -> {:ok, %{type: parse_outbox_type(raw), raw: raw}}
          error -> error
        end

      error ->
        error
    end
  end

  defp parse_outbox_type(raw) do
    case YamlElixir.read_from_string(raw) do
      {:ok, %{"type" => type}} -> outbox_type(type)
      _ -> :response
    end
  end

  defp outbox_type("continuing"), do: :continuing
  defp outbox_type("request"), do: :request
  defp outbox_type("silent"), do: :silent
  defp outbox_type(_), do: :response

  defp indent(text, n) do
    pad = String.duplicate(" ", n)

    text
    |> String.split("\n")
    |> Enum.join("\n#{pad}")
  end
end
