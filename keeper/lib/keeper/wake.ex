defmodule Keeper.Wake do
  @moduledoc "Executes one breath cycle: write inbox, run bootstrap, read outbox."

  alias Keeper.Sprites

  @doc """
  Execute one breath. Returns {:ok, %{type: atom, raw: string}} or {:error, reason}.

  The type is one of :response, :continuing, :request, :silent.
  On bootstrap failure, returns {:error, {:crash, reason}}.
  """
  def breathe(name, message, opts \\ []) do
    api_key = Keyword.get(opts, :api_key, System.get_env("ANTHROPIC_API_KEY"))
    inbox_yaml = build_inbox(message, opts)
    unix_ts = System.os_time(:second)

    with {:ok, _} <- clear_inbox(name),
         {:ok, _} <- Sprites.write_file(name, "/vivarium/inbox/#{unix_ts}.msg", inbox_yaml),
         {:ok, _} <- run_bootstrap(name, api_key) do
      read_and_parse_outbox(name)
    else
      {:error, reason} -> {:error, {:crash, reason}}
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

  defp run_bootstrap(name, api_key) do
    Sprites.exec(
      name,
      "ANTHROPIC_API_KEY='#{api_key}' python3 /vivarium/bootstrap/bootstrap.py"
    )
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
