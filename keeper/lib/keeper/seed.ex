defmodule Keeper.Seed do
  @moduledoc "Creates and seeds a new terrarium."

  alias Keeper.{Sprites, Config, Git}

  # Embed files at compile time so they're available in releases
  @soul_content File.read!(Path.expand("../../../seed/soul.md", __DIR__))
  @agents_md_content File.read!(Path.expand("../../../seed/AGENTS.md", __DIR__))

  # Recompile this module when these files change
  @external_resource Path.expand("../../../seed/soul.md", __DIR__)
  @external_resource Path.expand("../../../seed/AGENTS.md", __DIR__)

  # Path to the cross-compiled bootstrap binary for Sprites (linux x86_64).
  # Built separately via: cargo build --release --target x86_64-unknown-linux-musl
  # Read at runtime (not embedded) — binary is too large to compile into the module.
  @bootstrap_binary_path Path.expand(
                           "../../../bootstrap/target/x86_64-unknown-linux-musl/release/vivarium-bootstrap",
                           __DIR__
                         )

  # No @external_resource for the binary — it's read at runtime via File.read!/1

  def create(name, config \\ Config.new()) do
    with {:ok, _} <- Sprites.create(name),
         :ok <- create_dirs(name),
         :ok <- write_soul(name),
         :ok <- write_agents_md(name),
         :ok <- write_bootstrap(name),
         :ok <- write_config(name, config),
         :ok <- Git.init(name) do
      {:ok, name}
    end
  end

  defp create_dirs(name) do
    dirs =
      ~w(/vivarium/inbox /vivarium/outbox /vivarium/context/handoff_log
         /vivarium/tools /vivarium/data /vivarium/.keeper /vivarium/bootstrap
         /vivarium/public)
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

  defp write_agents_md(name) do
    case Sprites.write_file(name, "/vivarium/AGENTS.md", @agents_md_content) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp write_bootstrap(name) do
    binary = File.read!(@bootstrap_binary_path)

    with {:ok, _} <- Sprites.write_file(name, "/vivarium/bootstrap/vivarium-bootstrap", binary),
         {:ok, _} <- Sprites.exec(name, "chmod +x /vivarium/bootstrap/vivarium-bootstrap") do
      :ok
    end
  end

  defp write_config(name, config) do
    json = Config.to_bootstrap_json(config)

    case Sprites.write_file(name, "/vivarium/.keeper/bootstrap_config.json", json) do
      {:ok, _} -> :ok
      error -> error
    end
  end
end
