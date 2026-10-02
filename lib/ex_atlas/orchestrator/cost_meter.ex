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

  ## The provider's bill

  `reconcile/3` raises the spend to a provider's billed total for the current
  pod, and never lowers it: billing lags by an amount RunPod does not state,
  so a bill below the estimate may only be late. The meter remembers what the
  session had spent when the current pod started (`new_pod/2`), so a bill for
  one pod is compared with that pod's estimate, not the session's.

      iex> alias ExAtlas.Orchestrator.CostMeter
      iex> hour = 3_600_000
      iex> meter = CostMeter.new(10, 2.0, 0)
      iex> meter |> CostMeter.reconcile(1.5, div(hour, 2)) |> CostMeter.spent_usd(div(hour, 2))
      1.5
      iex> CostMeter.reconcile(meter, 0.4, div(hour, 2)) == meter
      true

  A meter resumed by `resume/4` counts its carried spend as the current pod's,
  since an adopted record does not say which pod spent it.
  """

  @ms_per_hour 3_600_000

  # A cap further away than the longest portable timer (about 49.7 days) is
  # re-checked when that timer fires.
  @max_timer_ms ExAtlas.Orchestrator.Timer.max_ms()
  @max_timer_hours @max_timer_ms / @ms_per_hour

  @enforce_keys [:max_cost, :rate, :spent_before, :since_ms]
  defstruct @enforce_keys ++ [pod_start_usd: 0.0]

  @type t :: %__MODULE__{
          max_cost: number(),
          rate: float(),
          spent_before: float(),
          since_ms: integer(),
          pod_start_usd: float()
        }

  @doc """
  Start a meter at `rate` dollars per hour, at monotonic time `now_ms`.

  A rate the meter cannot read starts it at `0.0`.
  """
  @spec new(number(), term(), integer()) :: t()
  def new(max_cost, rate, now_ms), do: resume(max_cost, 0.0, rate, now_ms)

  @doc """
  A meter that has already spent `spent_usd` in closed segments, with its open
  segment at `rate` since `since_ms`.

  An adopted task resumes its stored spend this way. A rate the meter cannot
  read starts the open segment at `0.0`.
  """
  @spec resume(number(), number(), term(), integer()) :: t()
  def resume(max_cost, spent_usd, rate, since_ms) do
    %__MODULE__{
      max_cost: max_cost,
      rate: known_rate(rate) || 0.0,
      spent_before: spent_usd / 1,
      since_ms: since_ms
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

  @doc """
  Mark `now_ms` as the start of a new pod, such as a respawn's replacement.

  Spend is unchanged; `pod_spent_usd/2` and `reconcile/3` count from here.
  """
  @spec new_pod(t(), integer()) :: t()
  def new_pod(%__MODULE__{} = meter, now_ms),
    do: %{meter | pod_start_usd: spent_usd(meter, now_ms)}

  @doc "Dollars the current pod has spent up to `now_ms`, by the estimate."
  @spec pod_spent_usd(t(), integer()) :: float()
  def pod_spent_usd(%__MODULE__{} = meter, now_ms),
    do: spent_usd(meter, now_ms) - meter.pod_start_usd

  @doc """
  Raise the current pod's spend to `billed_usd` at `now_ms`, when the bill is
  above `pod_spent_usd/2`.

  Returns the meter unchanged when the bill is at or below the estimate, or is
  not a non-negative number, so a caller can compare the two to learn whether
  the spend moved. The meter then keeps running at its rate.
  """
  @spec reconcile(t(), term(), integer()) :: t()
  def reconcile(%__MODULE__{} = meter, billed_usd, now_ms) do
    case usd(billed_usd) do
      nil ->
        meter

      billed ->
        gap = billed - pod_spent_usd(meter, now_ms)
        if gap > 0, do: %{meter | spent_before: meter.spent_before + gap}, else: meter
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
  rate, rounded up. `0` once it has, at any rate; otherwise `:infinity` at
  rate `0.0`. Never more than 4,294,967,295 (about 49.7 days); the caller
  re-checks then.
  """
  @spec ms_to_cap(t(), integer()) :: non_neg_integer() | :infinity
  def ms_to_cap(%__MODULE__{} = meter, now_ms) do
    left = meter.max_cost - spent_usd(meter, now_ms)

    cond do
      left <= 0 -> 0
      meter.rate == 0 -> :infinity
      # Compared by division, so a huge cap cannot overflow the multiplication.
      left / @max_timer_hours >= meter.rate -> @max_timer_ms
      true -> ceil(left * @ms_per_hour / meter.rate)
    end
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
  def priced?(rate), do: not is_nil(usd(rate))

  @doc """
  `value` as a float number of dollars, or `nil` when it is not a
  non-negative number or `Decimal` that a float can hold.

      iex> ExAtlas.Orchestrator.CostMeter.usd(2)
      2.0
      iex> ExAtlas.Orchestrator.CostMeter.usd(Integer.pow(10, 400))
      nil
  """
  @spec usd(term()) :: float() | nil
  def usd(value), do: known_rate(value)

  defp known_rate(rate) when is_float(rate) and rate >= 0, do: rate

  # An integer past this converts to a float only by raising, and a raise in
  # the tracker deletes a healthy pod.
  defp known_rate(rate) when is_integer(rate) and rate >= 0 and rate < 1.0e300, do: rate / 1

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
