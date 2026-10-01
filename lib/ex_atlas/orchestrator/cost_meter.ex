defmodule ExAtlas.Orchestrator.CostMeter do
  @moduledoc """
  The running estimate of what a tracked session has spent, against its
  `:max_cost`.

  Like `ExAtlas.Orchestrator.TaskOutcome`, this is a plain module rather than
  a process: `ExAtlas.Orchestrator.ComputeServer` holds one in its state and
  keeps one timer for the moment `ms_to_cap/2` names.

  Spend is `cost_per_hour × elapsed`, summed over segments. A segment starts
  with `new/3` and at every `rate_changed/3`, so a price that moves mid-run is
  charged at the old rate up to the change and the new one after it. Times are
  monotonic milliseconds, the clock `:max_runtime_ms` uses.

      iex> alias ExAtlas.Orchestrator.CostMeter
      iex> hour = 3_600_000
      iex> meter = CostMeter.new(2.50, 2.0, 0) |> CostMeter.rate_changed(3.0, div(hour, 2))
      iex> CostMeter.spent_usd(meter, hour)
      2.5
      iex> CostMeter.ms_to_cap(CostMeter.new(2.50, 0.0, 0), 0)
      :infinity

  A rate that is `nil`, negative or not a number keeps the last known rate: one
  poll that lost the price must not stop the meter. A `Decimal` rate is read
  as a float.
  """

  @ms_per_hour 3_600_000

  @enforce_keys [:max_cost, :rate, :spent_before, :since_ms]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          max_cost: number(),
          rate: float(),
          spent_before: float(),
          since_ms: integer()
        }

  @doc """
  Start a meter at `rate` dollars per hour, at monotonic time `now_ms`.

  A rate the meter cannot read starts it at `0.0`.
  """
  @spec new(number(), term(), integer()) :: t()
  def new(max_cost, rate, now_ms) do
    %__MODULE__{
      max_cost: max_cost,
      rate: known_rate(rate) || 0.0,
      spent_before: 0.0,
      since_ms: now_ms
    }
  end

  @doc """
  Close the current segment at `now_ms` and open one at `rate`.

  Returns the meter unchanged when `rate` cannot be read or equals the current
  rate, so a caller can compare the two to learn whether the rate moved.
  """
  @spec rate_changed(t(), term(), integer()) :: t()
  def rate_changed(%__MODULE__{rate: current} = meter, rate, now_ms) do
    case known_rate(rate) do
      nil ->
        meter

      ^current ->
        meter

      rate ->
        %{meter | rate: rate, spent_before: spent_usd(meter, now_ms), since_ms: now_ms}
    end
  end

  @doc "Dollars spent up to `now_ms`."
  @spec spent_usd(t(), integer()) :: float()
  def spent_usd(%__MODULE__{} = meter, now_ms),
    do: meter.spent_before + meter.rate * (now_ms - meter.since_ms) / @ms_per_hour

  @doc "Whether spend has reached `max_cost` at `now_ms`."
  @spec capped?(t(), integer()) :: boolean()
  def capped?(%__MODULE__{} = meter, now_ms), do: spent_usd(meter, now_ms) >= meter.max_cost

  @doc """
  Milliseconds from `now_ms` until spend reaches `max_cost` at the current
  rate, rounded up. `0` once it has; `:infinity` at rate `0.0`.
  """
  @spec ms_to_cap(t(), integer()) :: non_neg_integer() | :infinity
  def ms_to_cap(%__MODULE__{rate: rate}, _now_ms) when rate == 0, do: :infinity

  def ms_to_cap(%__MODULE__{} = meter, now_ms) do
    left = meter.max_cost - spent_usd(meter, now_ms)
    max(ceil(left * @ms_per_hour / meter.rate), 0)
  end

  @doc """
  Whether `rate` is a price the meter can read: a non-negative number or a
  `Decimal`.

      iex> ExAtlas.Orchestrator.CostMeter.priced?(2.99)
      true
      iex> ExAtlas.Orchestrator.CostMeter.priced?(nil)
      false
  """
  @spec priced?(term()) :: boolean()
  def priced?(rate), do: not is_nil(known_rate(rate))

  defp known_rate(rate) when is_number(rate) and rate >= 0, do: rate / 1

  # Decimal is not a dependency of ExAtlas, so its struct is read through its
  # `String.Chars` form rather than `Decimal.to_float/1`.
  defp known_rate(%{__struct__: Decimal} = rate) do
    case rate |> to_string() |> Float.parse() do
      {float, ""} -> known_rate(float)
      _not_finite -> nil
    end
  end

  defp known_rate(_unknown), do: nil
end
