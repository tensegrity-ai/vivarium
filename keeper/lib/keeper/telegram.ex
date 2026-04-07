defmodule Keeper.Telegram do
  @moduledoc """
  Telegram bot interface for the keeper. Long-polls for updates,
  dispatches slash commands, routes messages to terrariums.
  """
  use GenServer

  require Logger

  @poll_interval_ms 1_000
  @api_base "https://api.telegram.org/bot"

  defstruct [
    :token,
    offset: 0,
    chats: %{}
  ]

  @impl true
  def format_status(status) do
    Map.update(status, :state, nil, fn state ->
      %{state | token: "***"}
    end)
  end

  # -- Client API --

  def start_link(opts) do
    token = Keyword.fetch!(opts, :token)
    GenServer.start_link(__MODULE__, token, name: __MODULE__)
  end

  # -- Server --

  @impl true
  def init(token) do
    Logger.info("[telegram] bot starting")
    schedule_poll(0)
    {:ok, %__MODULE__{token: token}}
  end

  @impl true
  def handle_info(:poll, state) do
    state = poll_updates(state)
    schedule_poll(@poll_interval_ms)
    {:noreply, state}
  end

  def handle_info({:wake_result, chat_id, result}, state) do
    case result do
      {:ok, %{raw: raw, type: type}} ->
        content = parse_outbox_content(raw)
        prefix = if type == :continuing, do: "🔄 _Continuing..._\n\n", else: ""
        send_message(state.token, chat_id, prefix <> content)

      {:error, :runaway} ->
        send_message(state.token, chat_id, "⚠️ Runaway detected — too many continuations.")

      {:error, reason} ->
        send_message(state.token, chat_id, "❌ Error: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  def handle_info({ref, _result}, state) when is_reference(ref) do
    # Task completion message — already handled via :wake_result
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  # -- Polling --

  defp schedule_poll(delay) do
    Process.send_after(self(), :poll, delay)
  end

  defp poll_updates(state) do
    params = %{offset: state.offset, timeout: 30, allowed_updates: Jason.encode!(["message"])}

    case api_get(state.token, "getUpdates", params) do
      {:ok, %{"ok" => true, "result" => updates}} when updates != [] ->
        state = Enum.reduce(updates, state, &handle_update/2)
        last_id = updates |> List.last() |> Map.get("update_id")
        %{state | offset: last_id + 1}

      {:ok, %{"ok" => true}} ->
        state

      {:error, reason} ->
        Logger.warning("[telegram] poll error: #{inspect(reason)}")
        state
    end
  end

  # -- Update handling --

  defp handle_update(%{"message" => %{"text" => text, "chat" => %{"id" => chat_id}}}, state) do
    text = String.trim(text)

    cond do
      String.starts_with?(text, "/") -> handle_command(text, chat_id, state)
      true -> handle_message(text, chat_id, state)
    end
  end

  defp handle_update(_update, state), do: state

  # -- Commands --

  defp handle_command(text, chat_id, state) do
    {command, args} = parse_command(text)

    case command do
      "create" -> cmd_create(args, chat_id, state)
      "use" -> cmd_use(args, chat_id, state)
      "status" -> cmd_status(chat_id, state)
      "list" -> cmd_list(chat_id, state)
      "checkpoint" -> cmd_checkpoint(chat_id, state)
      "snapshot" -> cmd_snapshot(chat_id, state)
      "budget" -> cmd_budget(chat_id, state)
      "history" -> cmd_history(chat_id, state)
      "diff" -> cmd_diff(chat_id, state)
      "restore" -> cmd_restore(args, chat_id, state)
      "destroy" -> cmd_destroy(args, chat_id, state)
      "model" -> cmd_model(args, chat_id, state)
      "help" -> cmd_help(chat_id, state)
      _ -> send_and_return(state, chat_id, "Unknown command: /#{command}\nTry /help")
    end
  end

  defp cmd_create(args, chat_id, state) do
    name = String.trim(args)

    if name == "" do
      send_and_return(state, chat_id, "Usage: /create <name>")
    else
      send_message(state.token, chat_id, "Creating terrarium `#{name}`...")

      case Keeper.create(name) do
        :ok ->
          state = put_in(state.chats[chat_id], name)

          send_and_return(
            state,
            chat_id,
            "✅ Created and seeded `#{name}`\nNow active for this chat."
          )

        {:error, reason} ->
          send_and_return(state, chat_id, "❌ Create failed: #{inspect(reason)}")
      end
    end
  end

  defp cmd_use(args, chat_id, state) do
    name = String.trim(args)

    if name == "" do
      case state.chats[chat_id] do
        nil -> send_and_return(state, chat_id, "No active terrarium. Use /use <name>")
        name -> send_and_return(state, chat_id, "Active: `#{name}`")
      end
    else
      # Start a GenServer if one isn't already running for this sprite
      ensure_terrarium_started(name)
      state = put_in(state.chats[chat_id], name)
      send_and_return(state, chat_id, "Active terrarium set to `#{name}`")
    end
  end

  defp cmd_status(chat_id, state) do
    with_terrarium(state, chat_id, fn name ->
      status = Keeper.status(name)
      budget = status.budget

      msg = """
      📊 *#{name}*
      Status: #{status.status}
      Breaths: #{status.breath_count}
      Tokens: #{budget.tokens_used}
      Compute: #{budget.compute_ms}ms
      Crash recovery: #{status.crash_recovery}
      """

      send_and_return(state, chat_id, String.trim(msg))
    end)
  end

  defp cmd_list(chat_id, state) do
    case Keeper.Sprites.list() do
      {:ok, []} ->
        send_and_return(state, chat_id, "No sprites found.")

      {:ok, sprites} ->
        active = state.chats[chat_id]

        lines =
          Enum.map(sprites, fn %{name: name, status: status} ->
            marker = if name == active, do: " ← active", else: ""
            "• `#{name}` (#{status})#{marker}"
          end)

        send_and_return(state, chat_id, "Sprites:\n" <> Enum.join(lines, "\n"))

      {:error, reason} ->
        send_and_return(state, chat_id, "Failed to list sprites: #{inspect(reason)}")
    end
  end

  defp cmd_checkpoint(chat_id, state) do
    with_terrarium(state, chat_id, fn name ->
      case Keeper.checkpoint(name) do
        {:ok, meta} ->
          send_and_return(
            state,
            chat_id,
            "✅ Committed: `#{meta.id}` — #{meta.outbox_summary || "manual checkpoint"}"
          )

        {:error, reason} ->
          send_and_return(state, chat_id, "❌ Commit failed: #{inspect(reason)}")
      end
    end)
  end

  defp cmd_snapshot(chat_id, state) do
    with_terrarium(state, chat_id, fn name ->
      send_message(state.token, chat_id, "Creating VM snapshot...")

      case Keeper.snapshot(name) do
        {:ok, result} ->
          send_and_return(state, chat_id, "✅ VM snapshot created: #{inspect(result)}")

        {:error, reason} ->
          send_and_return(state, chat_id, "❌ Snapshot failed: #{inspect(reason)}")
      end
    end)
  end

  defp cmd_budget(chat_id, state) do
    with_terrarium(state, chat_id, fn name ->
      status = Keeper.status(name)
      budget = status.budget
      limits = status.config.budget

      msg = """
      💰 *Budget — #{name}*
      Tokens: #{budget.tokens_used} / #{limits.daily_tokens}
      Breaths: #{budget.breaths_used} / #{limits.daily_breaths}
      Compute: #{budget.compute_ms}ms / #{limits.daily_compute_ms}ms
      Period start: #{budget.period_start && DateTime.to_iso8601(budget.period_start)}
      """

      send_and_return(state, chat_id, String.trim(msg))
    end)
  end

  defp cmd_history(chat_id, state) do
    with_terrarium(state, chat_id, fn name ->
      case Keeper.history(name, limit: 10) do
        {:ok, []} ->
          send_and_return(state, chat_id, "No history yet.")

        {:ok, entries} ->
          lines =
            Enum.map(entries, fn meta ->
              "`#{meta.id}` breath #{meta.breath_number}: #{meta.outbox_summary}"
            end)

          send_and_return(state, chat_id, "📜 *History*\n" <> Enum.join(lines, "\n"))

        {:error, reason} ->
          send_and_return(state, chat_id, "❌ #{inspect(reason)}")
      end
    end)
  end

  defp cmd_diff(chat_id, state) do
    with_terrarium(state, chat_id, fn name ->
      case Keeper.Git.diff_last(name) do
        {:ok, ""} ->
          send_and_return(state, chat_id, "No changes in last breath.")

        {:ok, diff} ->
          truncated = String.slice(diff, 0, 3500)
          suffix = if String.length(diff) > 3500, do: "\n…(truncated)", else: ""
          send_and_return(state, chat_id, "```\n#{truncated}#{suffix}\n```")

        {:error, reason} ->
          send_and_return(state, chat_id, "❌ #{inspect(reason)}")
      end
    end)
  end

  defp cmd_restore(args, chat_id, state) do
    ref = String.trim(args)

    if ref == "" do
      send_and_return(state, chat_id, "Usage: /restore <commit-hash or HEAD~n>")
    else
      with_terrarium(state, chat_id, fn name ->
        case Keeper.Git.restore(name, ref) do
          {:ok, _} ->
            send_and_return(state, chat_id, "✅ Restored to `#{ref}`")

          {:error, reason} ->
            send_and_return(state, chat_id, "❌ Restore failed: #{inspect(reason)}")
        end
      end)
    end
  end

  defp cmd_destroy(args, chat_id, state) do
    name = String.trim(args)

    # Default to active terrarium if no name given
    name =
      if name == "" do
        state.chats[chat_id]
      else
        name
      end

    if is_nil(name) do
      send_and_return(state, chat_id, "Usage: /destroy <name>")
    else
      case Keeper.destroy(name) do
        {:ok, _} ->
          # Clear from active if it was active
          state =
            if state.chats[chat_id] == name do
              put_in(state.chats[chat_id], nil)
            else
              state
            end

          send_and_return(state, chat_id, "Destroyed #{name}")

        {:error, reason} ->
          send_and_return(state, chat_id, "Error: #{inspect(reason)}")
      end
    end
  end

  defp cmd_model(args, chat_id, state) do
    with_terrarium(state, chat_id, fn name ->
      model = String.trim(args)

      if model == "" do
        case Keeper.status(name) do
          %{config: %{model: current}} ->
            send_and_return(state, chat_id, "Model: `#{current}`")

          _ ->
            send_and_return(state, chat_id, "Could not read config.")
        end
      else
        case Keeper.set_model(name, model) do
          :ok ->
            send_and_return(state, chat_id, "Model set to `#{model}`")

          {:error, reason} ->
            send_and_return(state, chat_id, "Failed: #{inspect(reason)}")
        end
      end
    end)
  end

  defp cmd_help(chat_id, state) do
    msg = """
    *Vivarium Bot*

    /create <name> — create a new terrarium
    /destroy <name> — destroy a terrarium
    /use <name> — set active terrarium for this chat
    /list — list running terrariums
    /status — show terrarium status
    /budget — show budget usage
    /history — show breath history (git log)
    /diff — show last breath's changes
    /checkpoint — manual git commit
    /snapshot — full VM snapshot (disaster recovery)
    /model [name] — show or set the LLM model
    /restore <ref> — restore to a commit
    /help — this message

    Send any text to wake the active terrarium.
    """

    send_and_return(state, chat_id, String.trim(msg))
  end

  # -- Message (wake) --

  defp handle_message(text, chat_id, state) do
    with_terrarium(state, chat_id, fn name ->
      if cold?(name), do: send_message(state.token, chat_id, "Waking `#{name}`...")

      bot_pid = self()

      Task.Supervisor.start_child(Keeper.TaskSupervisor, fn ->
        result = Keeper.wake(name, text, channel: "telegram", from: "human")
        send(bot_pid, {:wake_result, chat_id, result})
      end)

      state
    end)
  end

  # -- Helpers --

  defp with_terrarium(state, chat_id, fun) do
    case state.chats[chat_id] do
      nil ->
        send_and_return(state, chat_id, "No active terrarium. Use /use <name> or /create <name>")

      name ->
        fun.(name)
    end
  end

  defp cold?(name) do
    case Keeper.Sprites.status(name) do
      {:ok, "cold"} -> true
      _ -> false
    end
  end

  defp ensure_terrarium_started(name) do
    case GenServer.whereis(Keeper.Terrarium.via(name)) do
      nil ->
        DynamicSupervisor.start_child(
          Keeper.TerrariumSupervisor,
          {Keeper.Terrarium, name}
        )

      _pid ->
        {:ok, :already_running}
    end
  end

  defp send_and_return(state, chat_id, text) do
    send_message(state.token, chat_id, text)
    state
  end

  defp parse_command(text) do
    # Strip the /command part, handle @botname suffix
    case String.split(text, " ", parts: 2) do
      [cmd] ->
        cmd = cmd |> String.trim_leading("/") |> String.split("@") |> hd()
        {cmd, ""}

      [cmd, args] ->
        cmd = cmd |> String.trim_leading("/") |> String.split("@") |> hd()
        {cmd, args}
    end
  end

  defp parse_outbox_content(raw) do
    case Jason.decode(raw) do
      {:ok, %{"content" => content}} when is_binary(content) -> String.trim(content)
      _ -> raw
    end
  end

  # -- Telegram API --

  defp api_get(token, method, params) do
    url = "#{@api_base}#{token}/#{method}"

    case Req.get(url, params: params, receive_timeout: 35_000) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, "HTTP #{status}: #{inspect(body)}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_message(token, chat_id, text) do
    url = "#{@api_base}#{token}/sendMessage"

    case Req.post(url, json: %{chat_id: chat_id, text: text, parse_mode: "Markdown"}) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: status, body: body}} ->
        # Markdown parsing can fail — retry without formatting
        if status == 400 do
          Req.post(url, json: %{chat_id: chat_id, text: text})
        end

        Logger.warning("[telegram] sendMessage #{status}: #{inspect(body)}")
        :ok

      {:error, reason} ->
        Logger.error("[telegram] sendMessage failed: #{inspect(reason)}")
        :error
    end
  end
end
