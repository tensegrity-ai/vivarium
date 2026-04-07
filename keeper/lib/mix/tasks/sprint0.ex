defmodule Mix.Tasks.Sprint0 do
  @moduledoc "Sprint 0 proof: seed → two breaths → two checkpoints."
  use Mix.Task

  @shortdoc "Run the Sprint 0 two-breath demo"

  def run(args) do
    name = List.first(args) || "vivarium-sprint0-#{System.os_time(:second)}"
    IO.puts("=== Sprint 0: #{name} ===\n")

    # Step 1: Seed
    IO.puts("→ Creating and seeding terrarium...")

    case Keeper.Seed.create(name) do
      {:ok, _} -> IO.puts("  ✓ Seeded\n")
      {:error, e} -> abort("Seed failed: #{e}")
    end

    # Step 2: First breath
    IO.puts("→ First breath: waking agent...")

    case Keeper.Wake.breathe(name, "You're alive. Read your soul. Look around. Make this place yours.") do
      {:ok, outbox} ->
        IO.puts("  ✓ First breath complete")
        IO.puts("  Outbox:\n#{indent(outbox)}\n")

      {:error, e} ->
        abort("First breath failed: #{e}")
    end

    # Checkpoint 1
    IO.puts("→ Checkpointing...")

    case Keeper.Sprites.checkpoint(name) do
      {:ok, out} -> IO.puts("  ✓ #{out}\n")
      {:error, e} -> abort("Checkpoint failed: #{e}")
    end

    # Step 3: Second breath
    IO.puts("→ Second breath: testing continuity...")

    case Keeper.Wake.breathe(name, "What do you remember from your first breath? What did you leave yourself?") do
      {:ok, outbox} ->
        IO.puts("  ✓ Second breath complete")
        IO.puts("  Outbox:\n#{indent(outbox)}\n")

      {:error, e} ->
        abort("Second breath failed: #{e}")
    end

    # Checkpoint 2
    IO.puts("→ Checkpointing...")

    case Keeper.Sprites.checkpoint(name) do
      {:ok, out} -> IO.puts("  ✓ #{out}\n")
      {:error, e} -> abort("Checkpoint failed: #{e}")
    end

    # Verify
    IO.puts("→ Reading handoff for verification...")

    case Keeper.Sprites.read_file(name, "/vivarium/context/handoff.md") do
      {:ok, handoff} -> IO.puts("  Handoff:\n#{indent(handoff)}\n")
      {:error, e} -> IO.puts("  Warning: couldn't read handoff: #{e}\n")
    end

    IO.puts("=== Sprint 0 complete: #{name} ===")
  end

  defp indent(text) do
    text |> String.split("\n") |> Enum.map_join("\n", &"    #{&1}")
  end

  defp abort(msg) do
    IO.puts("  ✗ #{msg}")
    System.halt(1)
  end
end
