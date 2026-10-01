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

  describe "capped?/2" do
    test "is true from the moment spend reaches the cap" do
      meter = CostMeter.new(1, 3600.0, 0)

      refute CostMeter.capped?(meter, 999)
      assert CostMeter.capped?(meter, 1_000)
    end
  end
end
