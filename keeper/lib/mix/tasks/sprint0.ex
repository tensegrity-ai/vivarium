defmodule Mix.Tasks.Sprint0 do
  @moduledoc "Sprint 0 proof: seed → two breaths → two checkpoints."
  use Mix.Task

  @shortdoc "Run the Sprint 0 two-breath demo"

  def run(args) do
    Mix.Task.run("app.start")

    name = List.first(args) || "vivarium-sprint0-#{System.os_time(:second)}"
    IO.puts("=== Sprint 0: #{name} ===\n")

    # Step 1: Create and seed
    IO.puts("→ Creating and seeding terrarium...")

    case Keeper.create(name) do
      :ok -> IO.puts("  ✓ Seeded\n")
      {:error, e} -> abort("Seed failed: #{e}")
    end

    # Step 2: First breath
    IO.puts("→ First breath: waking agent...")

    case Keeper.wake(name, "You're alive. Read your soul. Look around. Make this place yours.") do
      {:ok, %{raw: raw}} ->
        IO.puts("  ✓ First breath complete")
        IO.puts("  Outbox:\n#{indent(raw)}\n")

      {:error, e} ->
        abort("First breath failed: #{inspect(e)}")
    end

    IO.puts("→ Checkpointing...")

    case Keeper.checkpoint(name) do
      {:ok, out} -> IO.puts("  ✓ #{out}\n")
      {:error, e} -> abort("Checkpoint failed: #{e}")
    end

    # Step 3: Second breath
    IO.puts("→ Second breath: testing continuity...")

    case Keeper.wake(
           name,
           "What do you remember from your first breath? What did you leave yourself?"
         ) do
      {:ok, %{raw: raw}} ->
        IO.puts("  ✓ Second breath complete")
        IO.puts("  Outbox:\n#{indent(raw)}\n")

      {:error, e} ->
        abort("Second breath failed: #{inspect(e)}")
    end

    IO.puts("→ Checkpointing...")

    case Keeper.checkpoint(name) do
      {:ok, out} -> IO.puts("  ✓ #{out}\n")
      {:error, e} -> abort("Checkpoint failed: #{e}")
    end

    # Status
    status = Keeper.status(name)

    budget = status.budget

    IO.puts(
      "→ Final status: #{status.breath_count} breaths, #{length(status.checkpoint_history)} checkpoints, " <>
        "#{budget.tokens_used} tokens, #{budget.compute_ms}ms compute\n"
    )

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
