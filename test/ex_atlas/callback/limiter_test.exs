defmodule ExAtlas.Callback.LimiterTest do
  use ExUnit.Case, async: false

  alias ExAtlas.Callback.Limiter

  setup do
    start_supervised!(Limiter)
    :ok
  end

  defp task_id, do: "task-#{System.unique_integer([:positive])}"

  test "a fresh task may spend its whole burst and no more" do
    task = task_id()
    burst = Limiter.burst(:progress)

    for _ <- 1..burst, do: assert(:ok = Limiter.take(task, :progress))

    assert {:error, :rate_limited} = Limiter.take(task, :progress)
  end

  test "budgets are per kind — exhausting progress leaves logs and finish alone" do
    task = task_id()

    for _ <- 1..Limiter.burst(:progress), do: Limiter.take(task, :progress)
    assert {:error, :rate_limited} = Limiter.take(task, :progress)

    assert :ok = Limiter.take(task, :log)
    assert :ok = Limiter.take(task, :finish)
  end

  test "buckets are per task — one noisy pod cannot rate-limit another" do
    noisy = task_id()
    quiet = task_id()

    for _ <- 1..Limiter.burst(:log), do: Limiter.take(noisy, :log)
    assert {:error, :rate_limited} = Limiter.take(noisy, :log)

    assert :ok = Limiter.take(quiet, :log)
  end

  test "the bucket refills over time" do
    task = task_id()
    for _ <- 1..Limiter.burst(:progress), do: Limiter.take(task, :progress)
    assert {:error, :rate_limited} = Limiter.take(task, :progress)

    # `:now_ms` is the seam that lets the refill be tested without sleeping.
    later = System.monotonic_time(:millisecond) + 5_000
    assert :ok = Limiter.take(task, :progress, now_ms: later)
  end

  test "refill never exceeds the burst, so a long-idle pod cannot bank credit" do
    task = task_id()
    burst = Limiter.burst(:progress)
    an_hour_later = System.monotonic_time(:millisecond) + 3_600_000

    for _ <- 1..burst, do: assert(:ok = Limiter.take(task, :progress, now_ms: an_hour_later))
    assert {:error, :rate_limited} = Limiter.take(task, :progress, now_ms: an_hour_later)
  end

  test "finish is capped tightly enough that a pod cannot report repeatedly" do
    assert Limiter.burst(:finish) <= 3
  end

  test "idle buckets are swept, so an endless stream of task ids cannot grow the table" do
    task = task_id()
    burst = Limiter.burst(:progress)
    assert :ok = Limiter.take(task, :progress)

    Limiter.sweep(System.monotonic_time(:millisecond) + :timer.hours(1))

    # The bucket is gone, so the next caller starts from a full burst rather
    # than from the one token already spent. Asked at the *current* clock, so
    # only a dropped entry — not a refill — can explain the extra headroom.
    for _ <- 1..burst, do: assert(:ok = Limiter.take(task, :progress))
    assert {:error, :rate_limited} = Limiter.take(task, :progress)
  end
end
