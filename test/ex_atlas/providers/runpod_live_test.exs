defmodule ExAtlas.Providers.RunPodLiveTest do
  # Rents the cheapest GPU pod for about a minute against the real Runpod API.
  # Excluded by default; run with `RUNPOD_API_KEY=... mix test --only runpod_live`.
  use ExUnit.Case, async: false

  @moduletag :runpod_live
  @moduletag timeout: 20 * 60_000

  alias ExAtlas.Orchestrator.UpstreamStatus

  # Every key `Translate.pod_to_compute/2` reads.
  @read_keys ~w(id name status image gpu cost dataCenterId ports runtime createdAt startedAt)

  setup do
    key = System.fetch_env!("RUNPOD_API_KEY")
    opts = [provider: :runpod, api_key: key]
    name = "ex-atlas-live-test-#{System.unique_integer([:positive])}"

    # By name, not by id: a spawn that errors after Runpod made the pod never
    # returns an id. The Reaper's "atlas-" prefix never matches this name.
    on_exit(fn -> delete_by_name(name, opts) end)

    {:ok, opts: opts, name: name}
  end

  test "a pod runs its command, deletes itself, and reads as gone", %{opts: opts, name: name} do
    gpu = String.to_existing_atom(System.get_env("RUNPOD_LIVE_GPU", "rtx_a4000"))

    {:ok, compute} =
      ExAtlas.spawn_compute(
        [
          gpu: gpu,
          cloud_type: :community,
          image: "curlimages/curl:8.10.1",
          name: name,
          container_disk_gb: 5,
          command: ["sh", "-c", "sleep 20"],
          # curlimages/curl's ENTRYPOINT is curl; this one execs `cmd` as given.
          provider_opts: %{entrypoint: ["/bin/sh", "-c", "exec \"$@\"", "--"]}
        ] ++ opts
      )

    running = wait_until(compute.id, opts, &match?({:alive, %{status: :running}}, &1))
    {:alive, %{raw: raw}} = running

    for key <- @read_keys do
      assert Map.has_key?(raw, key), "GET /v2/pods/{id} has no #{key}"
    end

    assert {:dead, reason, _} = wait_until(compute.id, opts, &match?({:dead, _, _}, &1))
    assert reason in [:vanished, :terminated]
  end

  # PR 41's probe saw v2 refuse a pod body with no `disk`. With `templateId`
  # set the OpenAPI spec says the template supplies it; this test checks that
  # RunPod accepts the body and the pod keeps the template's port and disk.
  test "a pod spawned from a template with no ports and no disk is accepted and keeps the template's",
       %{opts: opts, name: name} do
    gpu = String.to_existing_atom(System.get_env("RUNPOD_LIVE_GPU", "rtx_a4000"))

    {:ok, template} =
      ExAtlas.create_template(
        [
          name: name,
          image: "curlimages/curl:8.10.1",
          ports: [{8000, :http}],
          container_disk_gb: 7
        ] ++ opts
      )

    on_exit(fn -> ExAtlas.delete_template(template.id, opts) end)

    assert {:ok, compute} =
             ExAtlas.spawn_compute(
               [gpu: gpu, cloud_type: :community, name: name, template_id: template.id] ++ opts
             )

    {:ok, pod} = ExAtlas.get_compute(compute.id, opts)
    assert pod.raw["ports"] == ["8000/http"]
    assert pod.raw["disk"] == 7
  end

  defp wait_until(id, opts, done?, deadline \\ System.monotonic_time(:second) + 900) do
    observation = UpstreamStatus.observe(id, opts)

    cond do
      done?.(observation) ->
        observation

      System.monotonic_time(:second) > deadline ->
        flunk("pod #{id} never got there; last observation #{inspect(observation)}")

      true ->
        Process.sleep(10_000)
        wait_until(id, opts, done?, deadline)
    end
  end

  defp delete_by_name(name, opts, attempts \\ 10)

  defp delete_by_name(name, _opts, 0),
    do: IO.warn("pods named #{name} may still be running; delete them in the Runpod console")

  defp delete_by_name(name, opts, attempts) do
    # A deleted pod may go on listing as TERMINATED for a while.
    case ExAtlas.list_compute([name: name] ++ opts) do
      {:ok, pods} when is_list(pods) and pods != [] ->
        pods |> Enum.reject(&(&1.status == :terminated)) |> terminate_all(name, opts, attempts)

      {:ok, []} ->
        :ok

      {:error, _} ->
        Process.sleep(5_000)
        delete_by_name(name, opts, attempts - 1)
    end
  end

  defp terminate_all([], _name, _opts, _attempts), do: :ok

  defp terminate_all(pods, name, opts, attempts) do
    Enum.each(pods, &ExAtlas.terminate(&1.id, opts))
    Process.sleep(5_000)
    delete_by_name(name, opts, attempts - 1)
  end
end
