defmodule ExAtlas.Orchestrator.Timer do
  @moduledoc false

  # The longest `Process.send_after/3` delay every OTP release accepts (about
  # 49.7 days). A longer delay raises, and a raise in a tracker deletes a
  # healthy pod, so every option that arms a timer stays at or under it.
  @max_ms 4_294_967_295

  @doc "The longest timer delay, in milliseconds, that every OTP release accepts."
  @spec max_ms() :: pos_integer()
  def max_ms, do: @max_ms

  @doc "The NimbleOptions type of a timer option: 1 to `max_ms/0` milliseconds."
  @spec option_type() :: {:in, Range.t()}
  def option_type, do: {:in, 1..@max_ms}
end
