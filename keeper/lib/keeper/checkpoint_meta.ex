defmodule Keeper.CheckpointMeta do
  @moduledoc "Structured metadata for a terrarium checkpoint (git commit)."

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
          timestamp: DateTime.t() | nil,
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

  @doc "Build a CheckpointMeta from a git commit hash and breath attributes."
  def new(commit_hash, attrs) do
    %__MODULE__{
      id: commit_hash,
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
end
