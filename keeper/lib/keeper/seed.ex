defmodule Keeper.Seed do
  @moduledoc "Creates and seeds a new terrarium."

  alias Keeper.{Sprites, Config, Git}

  @bootstrap_dir Path.expand("../../../bootstrap", __DIR__)
  @soul_path Path.expand("../../../seed/soul.md", __DIR__)
  @bootstrap_files ~w(bootstrap.py context.py tools.py requirements.txt)

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
    content = File.read!(@soul_path)

    case Sprites.write_file(name, "/vivarium/soul.md", content) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp write_bootstrap(name) do
    Enum.reduce_while(@bootstrap_files, :ok, fn file, :ok ->
      content = File.read!(Path.join(@bootstrap_dir, file))

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
