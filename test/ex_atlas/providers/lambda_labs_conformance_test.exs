defmodule ExAtlas.Providers.LambdaLabsConformanceTest do
  use ExUnit.Case, async: false

  use ExAtlas.Test.ProviderConformance,
    provider: :lambda_labs,
    reset: {ExAtlas.Test.FakeLambda, :start, []}

  alias ExAtlas.Test.FakeLambda

  # A ruleset costs nothing but counts against Lambda's quota, so a spawn and
  # terminate must leave none behind.
  describe "firewall rulesets" do
    test "a spawn with ports opens them, and terminate leaves no ruleset", %{call_opts: opts} do
      call = [provider: :lambda_labs, gpu: :h100, image: "test/image"] ++ opts

      {:ok, compute} = ExAtlas.spawn_compute(call ++ [ports: [{8000, :http}]])

      assert [%{"instance_ids" => [id], "rules" => [%{"port_range" => [8000, 8000]}]}] =
               FakeLambda.rulesets(opts)

      assert id == compute.id

      assert :ok = ExAtlas.terminate(compute.id, [provider: :lambda_labs] ++ opts)
      assert FakeLambda.rulesets(opts) == []
    end

    test "ten spawns and terminates leave no ruleset", %{call_opts: opts} do
      call = [provider: :lambda_labs, gpu: :h100, image: "test/image", name: "same"] ++ opts

      for _ <- 1..10 do
        {:ok, compute} = ExAtlas.spawn_compute(call ++ [ports: [{8000, :http}]])
        :ok = ExAtlas.terminate(compute.id, [provider: :lambda_labs] ++ opts)
      end

      assert FakeLambda.rulesets(opts) == []
    end

    test "a spawn without ports creates no ruleset", %{call_opts: opts} do
      {:ok, _} = ExAtlas.spawn_compute([provider: :lambda_labs, gpu: :h100, image: "i"] ++ opts)
      assert FakeLambda.rulesets(opts) == []
    end
  end
end
