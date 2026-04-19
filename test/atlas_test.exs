defmodule AtlasTest do
  use ExUnit.Case, async: false

  alias Atlas.Providers.Mock
  alias Atlas.Spec

  setup do
    Mock.reset()
    :ok
  end

  describe "spawn_compute/1" do
    test "raises when no provider is given and no default is configured" do
      Application.delete_env(:atlas, :default_provider)

      assert_raise ArgumentError, ~r/no :provider passed/, fn ->
        Atlas.spawn_compute(gpu: :h100, image: "x")
      end
    end

    test "dispatches to the provider module and returns a normalized Compute" do
      {:ok, compute} =
        Atlas.spawn_compute(provider: :mock, gpu: :h100, image: "test", ports: [{8000, :http}])

      assert %Spec.Compute{provider: :mock, status: :running} = compute
      assert [%{internal: 8000, protocol: :http}] = compute.ports
    end

    test "accepts a pre-built ComputeRequest struct" do
      req = Spec.ComputeRequest.new!(gpu: :h100, image: "test")
      {:ok, compute} = Atlas.spawn_compute(req, provider: :mock)
      assert compute.provider == :mock
    end

    test "accepts a user-provided provider module" do
      {:ok, compute} =
        Atlas.spawn_compute(provider: Atlas.Providers.Mock, gpu: :a100_80g, image: "x")

      assert compute.provider == :mock
    end
  end

  describe "get_compute / terminate / stop / start" do
    test "round-trip through mock provider" do
      {:ok, %{id: id}} = Atlas.spawn_compute(provider: :mock, gpu: :h100, image: "x")

      {:ok, fetched} = Atlas.get_compute(id, provider: :mock)
      assert fetched.id == id
      assert fetched.status == :running

      :ok = Atlas.stop(id, provider: :mock)
      {:ok, stopped} = Atlas.get_compute(id, provider: :mock)
      assert stopped.status == :stopped

      :ok = Atlas.start(id, provider: :mock)
      :ok = Atlas.terminate(id, provider: :mock)
      {:ok, gone} = Atlas.get_compute(id, provider: :mock)
      assert gone.status == :terminated
    end
  end

  describe "list_compute filters" do
    test "filters by status" do
      {:ok, a} = Atlas.spawn_compute(provider: :mock, gpu: :h100, image: "x")
      {:ok, b} = Atlas.spawn_compute(provider: :mock, gpu: :h100, image: "x")
      :ok = Atlas.stop(a.id, provider: :mock)

      {:ok, running} = Atlas.list_compute(provider: :mock, status: :running)
      assert Enum.map(running, & &1.id) == [b.id]
    end
  end

  describe "stub providers" do
    test "Fly returns :unsupported for spawn" do
      assert {:error, %Atlas.Error{kind: :unsupported}} =
               Atlas.spawn_compute(provider: :fly, gpu: :a100_80g, image: "x")
    end

    test "Fly still reports capabilities" do
      assert :http_proxy in Atlas.capabilities(:fly)
    end

    test "LambdaLabs returns :unsupported" do
      assert {:error, %Atlas.Error{kind: :unsupported}} =
               Atlas.spawn_compute(provider: :lambda_labs, gpu: :h100, image: "x")
    end

    test "Vast returns :unsupported" do
      assert {:error, %Atlas.Error{kind: :unsupported}} =
               Atlas.spawn_compute(provider: :vast, gpu: :h100, image: "x")
    end
  end

  describe "run_job" do
    test "echoes input through the mock provider" do
      {:ok, job} =
        Atlas.run_job(provider: :mock, endpoint: "abc", input: %{prompt: "hi"}, mode: :async)

      assert job.status == :completed
      assert job.output == %{"echo" => %{prompt: "hi"}}
    end
  end

  describe "list_gpu_types" do
    test "returns mock catalog" do
      {:ok, [gpu | _]} = Atlas.list_gpu_types(provider: :mock)
      assert %Spec.GpuType{provider: :mock, canonical: :h100} = gpu
    end
  end
end
