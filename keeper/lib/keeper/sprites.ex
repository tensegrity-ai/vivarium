defmodule Keeper.Sprites do
  @moduledoc """
  Wraps the `sprite` CLI for interacting with Fly.io Sprites.
  Sprint 0: shell out to CLI. Upgrade to HTTP API later.
  """

  @org "tensegrity-systems"
  @max_retries 2
  @sprite_bin "sprite"

  def create(name) do
    run([@sprite_bin, "create", "-o", @org, name])
  end

  def exec(name, command, _opts \\ []) do
    run([@sprite_bin, "exec", "-s", name, "-o", @org, "--", "bash", "-c", command])
  end

  def checkpoint(name) do
    run([@sprite_bin, "checkpoint", "create", "-s", name, "-o", @org])
  end

  def restore(name, version) do
    run([@sprite_bin, "restore", version, "-s", name, "-o", @org])
  end

  def destroy(name) do
    run([@sprite_bin, "destroy", name, "-o", @org, "--force"])
  end

  @doc "Write a file into the sprite. Uses base64 via exec to avoid quoting issues."
  def write_file(name, path, content) do
    encoded = Base.encode64(content)
    dir = Path.dirname(path)

    exec(name, "mkdir -p #{dir} && echo '#{encoded}' | base64 -d > #{path}")
  end

  @doc "Read a file from the sprite."
  def read_file(name, path) do
    exec(name, "cat #{path}")
  end

  # -- internal --

  defp run(argv) do
    [program | args] = argv
    do_run(program, args, 0)
  end

  defp do_run(program, args, attempt) do
    case System.cmd(program, args, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, String.trim(output)}

      {output, _code} ->
        if attempt < @max_retries and String.contains?(output, "502") do
          Process.sleep(1_000 * (attempt + 1))
          do_run(program, args, attempt + 1)
        else
          {:error, String.trim(output)}
        end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end
end
