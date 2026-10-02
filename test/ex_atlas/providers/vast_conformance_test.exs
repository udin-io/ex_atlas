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

  test "stop reads :stopped, start reads :running, and an unknown id is :not_found", %{
    call_opts: opts
  } do
    opts = [provider: :vast] ++ opts
    {:ok, compute} = ExAtlas.spawn_compute([gpu: :rtx_4090, image: "test/image"] ++ opts)

    assert :ok = ExAtlas.stop(compute.id, opts)
    assert {:ok, %{status: :stopped}} = ExAtlas.get_compute(compute.id, opts)

    assert :ok = ExAtlas.start(compute.id, opts)
    assert {:ok, %{status: :running}} = ExAtlas.get_compute(compute.id, opts)

    assert {:error, %ExAtlas.Error{kind: :not_found}} = ExAtlas.stop("1", opts)
    assert {:error, %ExAtlas.Error{kind: :not_found}} = ExAtlas.start("1", opts)
  end
end
