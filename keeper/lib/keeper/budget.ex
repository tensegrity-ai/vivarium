defmodule Keeper.Budget do
  @moduledoc "Tracks resource consumption per terrarium and enforces daily limits."

  defstruct tokens_used: 0,
            breaths_used: 0,
            compute_ms: 0,
            period_start: nil

  @doc "Create a new budget starting now."
  def new do
    %__MODULE__{period_start: beginning_of_day()}
  end

  @doc "Record a breath's resource consumption."
  def record(%__MODULE__{} = budget, tokens, compute_ms) do
    %{
      budget
      | tokens_used: budget.tokens_used + tokens,
        breaths_used: budget.breaths_used + 1,
        compute_ms: budget.compute_ms + compute_ms
    }
  end

  @doc "Check if budget is exhausted against the given limits."
  def exhausted?(%__MODULE__{} = budget, limits) do
    budget.tokens_used >= limits.daily_tokens or
      budget.breaths_used >= limits.daily_breaths or
      budget.compute_ms >= limits.daily_compute_ms
  end

  @doc "Reset if we've crossed a day boundary. Returns updated budget."
  def maybe_reset(%__MODULE__{period_start: start} = budget) do
    if DateTime.diff(DateTime.utc_now(), start, :second) >= 86_400 do
      %__MODULE__{period_start: beginning_of_day()}
    else
      budget
    end
  end

  @doc "Format budget status as YAML string for writing to the Sprite."
  def to_yaml(%__MODULE__{} = budget, limits) do
    """
    period: daily
    period_start: "#{DateTime.to_iso8601(budget.period_start)}"
    tokens:
      used: #{budget.tokens_used}
      limit: #{limits.daily_tokens}
      remaining: #{max(limits.daily_tokens - budget.tokens_used, 0)}
    breaths:
      used: #{budget.breaths_used}
      limit: #{limits.daily_breaths}
      remaining: #{max(limits.daily_breaths - budget.breaths_used, 0)}
    compute_ms:
      used: #{budget.compute_ms}
      limit: #{limits.daily_compute_ms}
      remaining: #{max(limits.daily_compute_ms - budget.compute_ms, 0)}
    """
  end

  defp beginning_of_day do
    DateTime.utc_now()
    |> Map.merge(%{hour: 0, minute: 0, second: 0, microsecond: {0, 0}})
  end
end
