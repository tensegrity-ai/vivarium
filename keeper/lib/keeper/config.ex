defmodule Keeper.Config do
  @moduledoc "Per-terrarium configuration."

  defstruct model: "claude-sonnet-4-20250514",
            context_limit: 200_000,
            max_response_tokens: 16_384,
            heartbeat_interval_ms: nil,
            budget: %{
              daily_tokens: 500_000,
              daily_breaths: 30,
              daily_compute_ms: :timer.minutes(15)
            }

  @doc "Build a Config from a keyword list, applying defaults."
  def new(opts \\ []) do
    config = struct(__MODULE__, opts)

    # Merge budget overrides
    case Keyword.get(opts, :budget) do
      nil -> config
      overrides -> %{config | budget: Map.merge(config.budget, Map.new(overrides))}
    end
  end

  @doc "Generate bootstrap_config.yaml content from this config."
  def to_bootstrap_yaml(%__MODULE__{} = config) do
    """
    provider: anthropic
    model: #{config.model}
    api_key_env: ANTHROPIC_API_KEY
    context_limit: #{config.context_limit}
    max_response_tokens: #{config.max_response_tokens}
    tool_timeout_seconds: 300
    """
  end
end
