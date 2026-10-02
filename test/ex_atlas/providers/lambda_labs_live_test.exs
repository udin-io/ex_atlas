defmodule ExAtlas.Providers.LambdaLabsLiveTest do
  # Rents Lambda's cheapest listed instance type for a few minutes against the
  # real Cloud API. Excluded by default; run with
  #
  #     LAMBDA_LABS_API_KEY=... LAMBDA_SSH_KEY_NAME=... mix test --only lambda_live
  #
  # Each test records one point the Bypass suite cannot settle (#84):
  # Lambda's real instance type names, whether cloud-init runs the bash
  # `user_data` on the default image, and what an `invalid-parameters` error
  # echoes. Set LAMBDA_LIVE_HTTP=1 once Lambda's firewall admits port 80 to
  # assert that nginx answers too.
  use ExUnit.Case, async: false

  @moduletag :lambda_live
  @moduletag timeout: 30 * 60_000

  alias ExAtlas.Orchestrator.UpstreamStatus
  alias ExAtlas.Providers.LambdaLabs.Client

  # Every key `Translate.instance_to_compute/2` reads.
  @read_keys ~w(id name status ip region instance_type tags)

  setup do
    key = System.fetch_env!("LAMBDA_LABS_API_KEY")
    ssh_key = System.fetch_env!("LAMBDA_SSH_KEY_NAME")
    opts = [provider: :lambda_labs, api_key: key]
    # Never the Reaper's "atlas-" prefix.
    name = "ex-atlas-live-test-#{System.unique_integer([:positive])}"

    # By name, not by id: a spawn that errors after Lambda launched never
    # returns an id.
    on_exit(fn -> delete_by_name(name, opts) end)

    {:ok, opts: opts, name: name, ssh_key: ssh_key}
  end

  test "the catalog lists names that follow gpu_<n>x_<family>", %{opts: opts} do
    assert {:ok, types} = ExAtlas.list_gpu_types(opts)
    IO.puts("\nLambda instance types: #{types |> Enum.map(& &1.id) |> Enum.join(", ")}")

    assert types != []
    assert Enum.all?(types, &Regex.match?(~r/\Agpu_\d+x_[a-z0-9_]+\z/, &1.id))
  end

  test "an instance runs nginx from user_data, reads running with an IP, and terminates", %{
    opts: opts,
    name: name,
    ssh_key: ssh_key
  } do
    {:ok, types} = ExAtlas.list_gpu_types(opts)

    cheapest =
      types
      |> Enum.reject(&(&1.stock == :unavailable))
      |> Enum.min_by(& &1.lowest_price_per_hour, fn -> flunk("no type has capacity") end)

    IO.puts("\nrenting #{cheapest.id} at $#{cheapest.lowest_price_per_hour}/h")

    {:ok, compute} =
      ExAtlas.spawn_compute(
        [
          gpu: :h100,
          name: name,
          image: "nginx:alpine",
          ports: [{80, :http}],
          env: %{"ATLAS_LIVE_MARKER" => "it's $(id)"},
          provider_opts: %{instance_type: cheapest.id, ssh_key_name: ssh_key}
        ] ++ opts
      )

    {:alive, running} = wait_until(compute.id, opts, &match?({:alive, %{status: :running}}, &1))
    assert is_binary(running.public_ip)
    assert [%{internal: 80, url: "http://" <> _ = url}] = running.ports

    for key <- @read_keys do
      assert Map.has_key?(running.raw, key), "GET /instances/{id} has no #{key}"
    end

    if System.get_env("LAMBDA_LIVE_HTTP") == "1" do
      assert {:ok, %{status: 200}} = wait_for_http(url)
    end

    assert :ok = ExAtlas.terminate(compute.id, opts)
    assert {:dead, reason, _} = wait_until(compute.id, opts, &match?({:dead, _, _}, &1))
    assert reason in [:vanished, :terminated]
  end

  # A region that does not exist and a tag key Lambda's pattern refuses, so
  # Lambda cannot launch: this spends nothing.
  test "a refused launch echoes no user_data value", %{opts: opts, ssh_key: ssh_key} do
    marker = "live-echo-probe-#{System.unique_integer([:positive])}"
    ctx = ExAtlas.Config.build_ctx(:lambda_labs, Keyword.delete(opts, :provider))

    result =
      Client.post(ctx, "/instance-operations/launch", %{
        "region_name" => "xx-nowhere-1",
        "instance_type_name" => "gpu_1x_a10",
        "ssh_key_names" => [ssh_key],
        "user_data" => ExAtlas.Secret.wrap("#!/bin/bash\nexport PROBE='#{marker}'\n"),
        "tags" => [%{"key" => "Bad Key", "value" => "probe-tag"}]
      })

    assert {:error, %ExAtlas.Error{} = error} = result
    IO.puts("\nLambda refused the probe: #{inspect(error.status)} #{inspect(error.raw)}")
    refute inspect(error) =~ marker, "Lambda echoes user_data in its error"
  end

  defp wait_until(id, opts, done?, deadline \\ System.monotonic_time(:second) + 1200) do
    observation = UpstreamStatus.observe(id, opts)

    cond do
      done?.(observation) ->
        observation

      System.monotonic_time(:second) > deadline ->
        flunk("instance #{id} never got there; last observation #{inspect(observation)}")

      true ->
        Process.sleep(15_000)
        wait_until(id, opts, done?, deadline)
    end
  end

  # cloud-init runs user_data after the instance reads active, and docker
  # pulls the image, so nginx answers some minutes later.
  defp wait_for_http(url, tries \\ 40) do
    case Req.get(url, retry: false, receive_timeout: 5_000) do
      {:ok, %{status: 200}} = ok ->
        ok

      other when tries > 1 ->
        IO.puts("#{url}: #{inspect(other, limit: 3)}")
        Process.sleep(15_000)
        wait_for_http(url, tries - 1)

      other ->
        other
    end
  end

  defp delete_by_name(name, opts, attempts \\ 10)

  defp delete_by_name(name, _opts, 0),
    do:
      IO.warn("instances named #{name} may still be running; terminate them in Lambda's console")

  defp delete_by_name(name, opts, attempts) do
    # A terminated instance may go on listing as terminating for a while.
    case ExAtlas.list_compute([name: name] ++ opts) do
      {:ok, instances} ->
        case Enum.reject(instances, &(&1.status == :terminated)) do
          [] ->
            :ok

          live ->
            Enum.each(live, &ExAtlas.terminate(&1.id, opts))
            Process.sleep(5_000)
            delete_by_name(name, opts, attempts - 1)
        end

      {:error, _} ->
        Process.sleep(5_000)
        delete_by_name(name, opts, attempts - 1)
    end
  end
end
