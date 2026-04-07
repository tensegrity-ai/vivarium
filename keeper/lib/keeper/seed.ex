defmodule Keeper.Seed do
  @moduledoc "Creates and seeds a new terrarium."

  alias Keeper.{Sprites, Config, Git}

  # Embed files at compile time so they're available in releases
  @soul_content File.read!(Path.expand("../../../seed/soul.md", __DIR__))
  @bootstrap_contents %{
    "bootstrap.py" => File.read!(Path.expand("../../../bootstrap/bootstrap.py", __DIR__)),
    "context.py" => File.read!(Path.expand("../../../bootstrap/context.py", __DIR__)),
    "tools.py" => File.read!(Path.expand("../../../bootstrap/tools.py", __DIR__)),
    "requirements.txt" => File.read!(Path.expand("../../../bootstrap/requirements.txt", __DIR__))
  }

  # Recompile this module when these files change
  @external_resource Path.expand("../../../seed/soul.md", __DIR__)
  @external_resource Path.expand("../../../bootstrap/bootstrap.py", __DIR__)
  @external_resource Path.expand("../../../bootstrap/context.py", __DIR__)
  @external_resource Path.expand("../../../bootstrap/tools.py", __DIR__)
  @external_resource Path.expand("../../../bootstrap/requirements.txt", __DIR__)

  def create(name, config \\ Config.new()) do
    with {:ok, _} <- Sprites.create(name),
         :ok <- create_dirs(name),
         :ok <- write_soul(name),
         :ok <- write_bootstrap(name),
         :ok <- write_config(name, config),
         :ok <- install_deps(name),
         :ok <- Git.init(name) do
      {:ok, name}
    end
  end

  defp create_dirs(name) do
    dirs =
      ~w(/vivarium/inbox /vivarium/outbox /vivarium/context/handoff_log
         /vivarium/tools /vivarium/data /vivarium/.keeper /vivarium/bootstrap)
      |> Enum.join(" ")

    case Sprites.exec(name, "mkdir -p #{dirs}") do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp write_soul(name) do
    case Sprites.write_file(name, "/vivarium/soul.md", @soul_content) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp write_bootstrap(name) do
    Enum.reduce_while(@bootstrap_contents, :ok, fn {file, content}, :ok ->
      case Sprites.write_file(name, "/vivarium/bootstrap/#{file}", content) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp write_config(name, config) do
    yaml = Config.to_bootstrap_yaml(config)

    case Sprites.write_file(name, "/vivarium/.keeper/bootstrap_config.yaml", yaml) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp install_deps(name) do
    case Sprites.exec(name, "pip install -r /vivarium/bootstrap/requirements.txt") do
      {:ok, _} -> :ok
      error -> error
    end
  end
end
