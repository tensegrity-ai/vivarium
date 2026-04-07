defmodule Keeper.CheckpointMeta do
  @moduledoc "Structured metadata for a terrarium checkpoint."

  defstruct [
    :id,
    :timestamp,
    :trigger,
    :breath_number,
    :tokens_used,
    :compute_ms,
    :outbox_type,
    :outbox_summary,
    :comment,
    pinned: false,
    branch_parent: nil
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          timestamp: DateTime.t(),
          trigger: :message | :heartbeat | :scheduled | :continuation | :crash,
          breath_number: non_neg_integer(),
          tokens_used: non_neg_integer(),
          compute_ms: non_neg_integer(),
          outbox_type: :response | :continuing | :request | :silent | nil,
          outbox_summary: String.t() | nil,
          comment: String.t() | nil,
          pinned: boolean(),
          branch_parent: String.t() | nil
        }

  @doc "Build a CheckpointMeta from checkpoint result and breath context."
  def new(checkpoint_result, attrs) do
    %__MODULE__{
      id: extract_id(checkpoint_result),
      timestamp: DateTime.utc_now(),
      trigger: Keyword.get(attrs, :trigger, :message),
      breath_number: Keyword.get(attrs, :breath_number, 0),
      tokens_used: Keyword.get(attrs, :tokens_used, 0),
      compute_ms: Keyword.get(attrs, :compute_ms, 0),
      outbox_type: Keyword.get(attrs, :outbox_type),
      outbox_summary: Keyword.get(attrs, :outbox_summary),
      comment: Keyword.get(attrs, :comment)
    }
  end

  defp extract_id(%{"id" => id}), do: id
  defp extract_id(%{"version" => v}), do: v
  defp extract_id(str) when is_binary(str), do: parse_id_from_output(str)
  defp extract_id(_), do: nil

  defp parse_id_from_output(output) do
    # CLI output often contains "Created checkpoint v3" or similar
    case Regex.run(~r/\b(v\d+|cp_[a-zA-Z0-9]+)\b/, output) do
      [_, id] -> id
      _ -> output
    end
  end
end
