defmodule ExAtlas.Spec.Job do
  @moduledoc "Normalized representation of a serverless inference job."

  @enforce_keys [:id, :provider, :status]
  defstruct id: nil,
            provider: nil,
            endpoint: nil,
            status: :in_queue,
            output: nil,
            error: nil,
            execution_time_ms: nil,
            delay_time_ms: nil,
            created_at: nil,
            raw: %{}

  @type status :: :in_queue | :in_progress | :completed | :failed | :cancelled | :timed_out

  @type t :: %__MODULE__{
          id: String.t(),
          provider: atom(),
          endpoint: String.t() | nil,
          status: status(),
          output: term(),
          error: term(),
          execution_time_ms: non_neg_integer() | nil,
          delay_time_ms: non_neg_integer() | nil,
          created_at: DateTime.t() | nil,
          raw: map()
        }
end
