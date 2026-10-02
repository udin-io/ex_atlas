defmodule ExAtlas.Providers.VastConformanceTest do
  use ExUnit.Case, async: false

  use ExAtlas.Test.ProviderConformance,
    provider: :vast,
    reset: {ExAtlas.Test.FakeVast, :start, []}

  test "a terminated instance reads :not_found", %{call_opts: opts} do
    {:ok, compute} =
      ExAtlas.spawn_compute([provider: :vast, gpu: :rtx_4090, image: "test/image"] ++ opts)

    :ok = ExAtlas.terminate(compute.id, [provider: :vast] ++ opts)

    assert {:error, %ExAtlas.Error{kind: :not_found}} =
             ExAtlas.get_compute(compute.id, [provider: :vast] ++ opts)
  end
end
