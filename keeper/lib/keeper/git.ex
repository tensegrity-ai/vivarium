defmodule Keeper.Git do
  @moduledoc """
  Git operations inside a terrarium, executed via Sprites.exec.
  Manages the /vivarium/ repository for breath-level version control.
  """

  alias Keeper.{Sprites, CheckpointMeta}

  @vivarium_dir "/vivarium"
  @author_name "vivarium"
  @author_email "vivarium@local"

  @gitignore """
  inbox/
  outbox/
  .keeper/
  bootstrap/
  """

  # -- Setup --

  @doc "Initialize a git repo in /vivarium/ with .gitignore and initial commit."
  def init(name) do
    script = """
    cd #{@vivarium_dir} && \
    git init && \
    git config --global --add safe.directory #{@vivarium_dir} && \
    git config user.name '#{@author_name}' && \
    git config user.email '#{@author_email}' && \
    cat > .gitignore <<'VIVARIUM_GITIGNORE'
    #{String.trim(@gitignore)}
    VIVARIUM_GITIGNORE
    git add -A && \
    git commit -m 'seed: initial terrarium'
    """

    case Sprites.exec(name, script) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # -- Commit --

  @doc """
  Commit the current state of /vivarium/ with metadata.
  Uses --allow-empty so every breath is recorded even if no tracked files changed.
  Returns {:ok, %CheckpointMeta{}} or {:error, reason}.
  """
  def commit(name, attrs \\ []) do
    message = format_commit_message(attrs)

    script = """
    cd #{@vivarium_dir} && \
    cat > /tmp/vivarium_commit_msg <<'VIVARIUM_COMMIT_EOF'
    #{message}
    VIVARIUM_COMMIT_EOF
    git add -A && \
    git commit --allow-empty -F /tmp/vivarium_commit_msg && \
    rm -f /tmp/vivarium_commit_msg
    """

    case Sprites.exec(name, script) do
      {:ok, output} ->
        hash = parse_commit_hash(output)
        {:ok, CheckpointMeta.new(hash, attrs)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -- History --

  @doc "Read git log as a list of CheckpointMeta structs."
  def log(name, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    format = "%H%n%aI%n%s%n%b%nVIVARIUM_END"

    case Sprites.exec(name, "cd #{@vivarium_dir} && git log --format='#{format}' -n #{limit}") do
      {:ok, ""} ->
        {:ok, []}

      {:ok, output} ->
        entries =
          output
          |> String.split("VIVARIUM_END\n", trim: true)
          |> Enum.map(&parse_log_entry/1)
          |> Enum.reject(&is_nil/1)

        {:ok, entries}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -- Diff --

  @doc "Diff between two refs."
  def diff(name, from_ref, to_ref) do
    Sprites.exec(name, "cd #{@vivarium_dir} && git diff #{from_ref}..#{to_ref}")
  end

  @doc "Diff of the most recent commit."
  def diff_last(name) do
    Sprites.exec(name, "cd #{@vivarium_dir} && git diff HEAD~1..HEAD")
  end

  # -- Restore --

  @doc "Hard reset to a specific ref (commit hash, HEAD~n, etc)."
  def restore(name, ref) do
    Sprites.exec(name, "cd #{@vivarium_dir} && git reset --hard #{ref}")
  end

  # -- Branch --

  @doc "Create and switch to a new branch."
  def branch(name, branch_name) do
    Sprites.exec(name, "cd #{@vivarium_dir} && git checkout -b #{branch_name}")
  end

  @doc "List branches."
  def branches(name) do
    Sprites.exec(name, "cd #{@vivarium_dir} && git branch --list")
  end

  # -- Internal --

  defp format_commit_message(attrs) do
    breath = Keyword.get(attrs, :breath_number, 0)
    summary = Keyword.get(attrs, :outbox_summary, "breath completed")
    trigger = Keyword.get(attrs, :trigger, :message)
    tokens = Keyword.get(attrs, :tokens_used, 0)
    compute_ms = Keyword.get(attrs, :compute_ms, 0)
    outbox_type = Keyword.get(attrs, :outbox_type)

    subject = "breath #{breath}: #{summary}"

    body =
      [
        "trigger: #{trigger}",
        "tokens: #{tokens}",
        "compute_ms: #{compute_ms}",
        if(outbox_type, do: "outbox_type: #{outbox_type}")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    "#{subject}\n\n#{body}"
  end

  defp parse_commit_hash(output) do
    case Regex.run(~r/\[[\w\/.-]+ ([a-f0-9]+)\]/, output) do
      [_, hash] -> hash
      _ -> nil
    end
  end

  defp parse_log_entry(raw) do
    lines = String.split(String.trim(raw), "\n")

    case lines do
      [hash, date, subject | body_lines] ->
        body = Enum.join(body_lines, "\n") |> String.trim()
        attrs = parse_body_attrs(body)

        breath_number =
          case Regex.run(~r/^breath (\d+):/, subject) do
            [_, n] -> String.to_integer(n)
            _ -> 0
          end

        summary =
          case Regex.run(~r/^breath \d+: (.+)$/, subject) do
            [_, s] -> s
            _ -> subject
          end

        timestamp =
          case DateTime.from_iso8601(date) do
            {:ok, dt, _} -> dt
            _ -> nil
          end

        %CheckpointMeta{
          id: String.slice(hash, 0, 7),
          timestamp: timestamp,
          trigger: parse_trigger(attrs["trigger"]),
          breath_number: breath_number,
          tokens_used: parse_int(attrs["tokens"]),
          compute_ms: parse_int(attrs["compute_ms"]),
          outbox_type: parse_outbox_type(attrs["outbox_type"]),
          outbox_summary: summary
        }

      _ ->
        nil
    end
  end

  defp parse_body_attrs(body) do
    body
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ": ", parts: 2) do
        [key, value] -> Map.put(acc, String.trim(key), String.trim(value))
        _ -> acc
      end
    end)
  end

  defp parse_trigger(nil), do: :message
  defp parse_trigger("heartbeat"), do: :heartbeat
  defp parse_trigger("scheduled"), do: :scheduled
  defp parse_trigger("continuation"), do: :continuation
  defp parse_trigger("crash"), do: :crash
  defp parse_trigger(_), do: :message

  defp parse_outbox_type(nil), do: nil
  defp parse_outbox_type("response"), do: :response
  defp parse_outbox_type("continuing"), do: :continuing
  defp parse_outbox_type("request"), do: :request
  defp parse_outbox_type("silent"), do: :silent
  defp parse_outbox_type(_), do: nil

  defp parse_int(nil), do: 0
  defp parse_int(str), do: String.to_integer(str)
end
