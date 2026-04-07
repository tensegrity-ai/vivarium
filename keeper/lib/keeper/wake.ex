defmodule Keeper.Wake do
  @moduledoc "Executes one breath cycle: write inbox, run bootstrap, read outbox."

  alias Keeper.Sprites

  def breathe(name, message, opts \\ []) do
    api_key = Keyword.get(opts, :api_key, System.get_env("ANTHROPIC_API_KEY"))
    from = Keyword.get(opts, :from, "human")
    channel = Keyword.get(opts, :channel, "cli")
    ts = DateTime.utc_now() |> DateTime.to_iso8601()
    unix_ts = System.os_time(:second)

    inbox_msg = """
    type: message
    timestamp: "#{ts}"
    from: #{from}
    channel: #{channel}
    content: |
      #{indent(message, 2)}
    """

    with {:ok, _} <- Sprites.write_file(name, "/vivarium/inbox/#{unix_ts}.msg", inbox_msg),
         {:ok, _} <- run_bootstrap(name, api_key),
         {:ok, outbox} <- read_latest_outbox(name) do
      {:ok, outbox}
    end
  end

  defp run_bootstrap(name, api_key) do
    Sprites.exec(
      name,
      "ANTHROPIC_API_KEY='#{api_key}' python3 /vivarium/bootstrap/bootstrap.py"
    )
  end

  defp read_latest_outbox(name) do
    case Sprites.exec(name, "ls -t /vivarium/outbox/*.msg 2>/dev/null | head -1") do
      {:ok, ""} -> {:ok, "(no outbox message)"}
      {:ok, path} -> Sprites.read_file(name, String.trim(path))
      error -> error
    end
  end

  defp indent(text, n) do
    pad = String.duplicate(" ", n)

    text
    |> String.split("\n")
    |> Enum.join("\n#{pad}")
  end
end
