defmodule ExAtlas.Spec.SpendTest do
  use ExUnit.Case, async: true

  alias ExAtlas.Spec.Spend

  test "a Spend needs a compute id and a provider" do
    assert_raise ArgumentError, ~r/enforce_keys|:compute_id/, fn ->
      struct!(Spend, provider: :runpod)
    end
  end
end
