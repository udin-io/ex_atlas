defmodule ExAtlas.Orchestrator.CostMeterTest do
  use ExUnit.Case, async: true

  alias ExAtlas.Orchestrator.CostMeter

  doctest CostMeter

  @hour 3_600_000

  describe "spent_usd/2" do
    test "is the rate times the hours since the meter started" do
      meter = CostMeter.new(10, 2.0, 1_000)

      assert CostMeter.spent_usd(meter, 1_000) == 0.0
      assert CostMeter.spent_usd(meter, 1_000 + div(@hour, 2)) == 1.0
    end

    test "sums each segment at its own rate" do
      meter =
        CostMeter.new(10, 2.0, 0)
        |> CostMeter.rate_changed(4.0, @hour)

      # One hour at 2.0, then half an hour at 4.0.
      assert CostMeter.spent_usd(meter, @hour + div(@hour, 2)) == 4.0
    end

    test "an integer rate counts as a float" do
      assert CostMeter.spent_usd(CostMeter.new(10, 3, 0), @hour) == 3.0
    end
  end

  describe "resume/4" do
    test "adds the open segment's spend to the spend carried in" do
      meter = CostMeter.resume(10, 1.5, 2.0, 0)

      assert CostMeter.spent_usd(meter, 0) == 1.5
      assert CostMeter.spent_usd(meter, @hour) == 3.5
    end

    test "counts the carried spend against the cap" do
      meter = CostMeter.resume(2.5, 2.0, 3600.0, 0)

      # $0.50 left at $1 a second.
      assert CostMeter.ms_to_cap(meter, 0) == 500
    end

    test "a rate it cannot read starts the open segment at 0.0" do
      meter = CostMeter.resume(10, 1.5, nil, 0)

      assert CostMeter.spent_usd(meter, @hour) == 1.5
    end
  end

  describe "rate_changed/3" do
    test "a rate that is nil, negative or not a number keeps the last known rate" do
      meter = CostMeter.new(10, 2.0, 0)

      for unknown <- [nil, -1.0, "2.5", :free] do
        assert CostMeter.spent_usd(CostMeter.rate_changed(meter, unknown, 0), @hour) == 2.0
      end
    end

    test "a drop to 0.0 stops the spend where it stood" do
      meter = CostMeter.new(10, 2.0, 0) |> CostMeter.rate_changed(0.0, @hour)

      assert CostMeter.spent_usd(meter, 5 * @hour) == 2.0
    end
  end

  describe "ms_to_cap/2" do
    test "is the time left at the current rate, rounded up" do
      meter = CostMeter.new(1, 3600.0, 0)

      assert CostMeter.ms_to_cap(meter, 0) == 1_000
      assert CostMeter.ms_to_cap(meter, 400) == 600
    end

    test "is 0 once the cap is reached or passed" do
      meter = CostMeter.new(1, 3600.0, 0)

      assert CostMeter.ms_to_cap(meter, 1_000) == 0
      assert CostMeter.ms_to_cap(meter, 5_000) == 0
    end

    test "is :infinity at rate 0.0, so no timer is armed" do
      assert CostMeter.ms_to_cap(CostMeter.new(1, 0.0, 0), 0) == :infinity
    end

    test "is 0 at rate 0.0 once the carried spend has reached the cap" do
      # An adopted record whose budget ran out while the node was down, on a
      # pod that now reads $0 an hour.
      assert CostMeter.ms_to_cap(CostMeter.resume(1, 1.0, 0.0, 0), 0) == 0
      assert CostMeter.ms_to_cap(CostMeter.resume(1, 2.0, nil, 0), 0) == 0
    end

    test "is never longer than the longest timer every OTP release accepts" do
      # $1000 at $0.0001 per hour is 3.6e13 ms; Process.send_after raises above
      # its limit, and a raise in the tracker deletes a healthy pod.
      assert CostMeter.ms_to_cap(CostMeter.new(1000, 0.0001, 0), 0) == 4_294_967_295
    end

    test "a cap too large to multiply does not raise" do
      assert CostMeter.ms_to_cap(CostMeter.new(1.0e305, 1.0, 0), 0) == 4_294_967_295
    end

    test "follows a rate change" do
      meter = CostMeter.new(2, 3600.0, 0) |> CostMeter.rate_changed(7200.0, 1_000)

      # $1 spent in the first second; $1 left at $2/s.
      assert CostMeter.ms_to_cap(meter, 1_000) == 500
    end
  end

  describe "reconcile/3" do
    test "a bill above this pod's estimate raises the spend to the bill" do
      meter = CostMeter.new(10, 2.0, 0) |> CostMeter.reconcile(1.5, div(@hour, 2))

      # $1.00 estimated after half an hour; the bill says $1.50.
      assert CostMeter.spent_usd(meter, div(@hour, 2)) == 1.5
      # The meter keeps running at the pod's rate from there.
      assert CostMeter.spent_usd(meter, @hour) == 2.5
    end

    test "a bill at or below this pod's estimate changes nothing" do
      meter = CostMeter.new(10, 2.0, 0)

      for billed <- [1.0, 0.4, 0.0] do
        assert CostMeter.reconcile(meter, billed, div(@hour, 2)) == meter
      end
    end

    test "a bill that is not a number changes nothing" do
      meter = CostMeter.new(10, 2.0, 0)

      for billed <- [nil, -1.0, "9.99"] do
        assert CostMeter.reconcile(meter, billed, @hour) == meter
      end
    end

    test "after a new pod it compares the bill with that pod's spend alone" do
      # $2 on the first pod, then a new pod at the same rate.
      meter = CostMeter.new(10, 2.0, 0) |> CostMeter.new_pod(@hour)

      # Half an hour into the new pod: $1 estimated for it, $3 for the session.
      assert CostMeter.pod_spent_usd(meter, @hour + div(@hour, 2)) == 1.0

      # Its bill of $1.75 is above its own $1, though below the session's $3.
      raised = CostMeter.reconcile(meter, 1.75, @hour + div(@hour, 2))
      assert CostMeter.spent_usd(raised, @hour + div(@hour, 2)) == 3.75
    end

    test "a raised spend moves the cap closer" do
      meter = CostMeter.new(2, 3600.0, 0) |> CostMeter.reconcile(1.5, 0)

      # $0.50 left at $1 a second.
      assert CostMeter.ms_to_cap(meter, 0) == 500
    end

    test "a bill over the cap at a price of 0 caps at once" do
      meter = CostMeter.new(1, 0.0, 0) |> CostMeter.reconcile(1.2, @hour)

      assert CostMeter.capped?(meter, @hour)
      assert CostMeter.ms_to_cap(meter, @hour) == 0
    end
  end

  describe "pod_spent_usd/2" do
    test "is the whole spend until the first new pod" do
      meter = CostMeter.resume(10, 1.5, 2.0, 0)

      assert CostMeter.pod_spent_usd(meter, @hour) == 3.5
    end
  end

  describe "capped?/2" do
    test "is true from the moment spend reaches the cap" do
      meter = CostMeter.new(1, 3600.0, 0)

      refute CostMeter.capped?(meter, 999)
      assert CostMeter.capped?(meter, 1_000)
    end
  end
end
