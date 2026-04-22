defmodule ExAtlas.Fly.Deploy do
  @moduledoc """
  Discovers Fly.io apps (via `fly.toml`) and runs deploys against them.

  `deploy/2` runs `fly deploy --remote-only` via `System.cmd/3` with a 15 min
  timeout. `stream_deploy/3` uses `Port.open` to stream output line-by-line
  through `ExAtlas.Fly.Dispatcher`, with a 5 min activity timeout and a 30 min
  absolute cap.

  Streamed output lands as `{:ex_atlas_fly_deploy, ticket_id, line}` on the topic
  `"ex_atlas_fly_deploy:\#{ticket_id}"`.

  ## Error shape

  Both `deploy/2` and `stream_deploy/3` return the same error shape on
  failure:

      {:error, :invalid_deploy_dir}
        | {:error, {:fly_error, :not_found, String.t()}}
        | {:error, {:fly_error, :timeout,   String.t()}}
        | {:error, {:fly_error, non_neg_integer(), String.t()}}  # exit code + captured output

  `:not_found` means the `fly` executable is not on `PATH`; `:timeout` means
  the 15 min (`deploy/2`) or 30 min (`stream_deploy/3`) cap was hit; a
  positive integer is the process exit code. The third element is always a
  human-readable string (captured output or a short explanation) suitable
  for logging — do not pattern match on it.
  """

  require Logger

  alias ExAtlas.Fly.Dispatcher

  # Inactivity timeout: reset on each line of output (5 min)
  @fly_activity_timeout_ms 300_000
  # Absolute max deploy time (30 min)
  @fly_max_timeout_ms 1_800_000
  # Non-streaming deploy timeout (15 min)
  @fly_deploy_timeout_ms 900_000

  @type fly_error_reason :: :not_found | :timeout | non_neg_integer()
  @type deploy_error ::
          :invalid_deploy_dir
          | {:fly_error, fly_error_reason(), String.t()}

  @doc """
  Scan `project_path` for Fly apps (root `fly.toml` + `:max_depth` levels of
  subdirectories, default `1`).

  Returns a sorted list of `{app_name, directory}` tuples.

  ## Options

    * `:max_depth` — how many subdirectory levels below `project_path` to
      descend when searching for `fly.toml` files. Default `1`. Set higher
      (e.g. `2` or `3`) for monorepos that nest Fly apps under `apps/*/`
      or `services/*/` trees.
  """
  @spec discover_apps(String.t(), keyword()) :: [{String.t(), String.t()}]
  def discover_apps(project_path, opts \\ []) do
    max_depth = Keyword.get(opts, :max_depth, 1)

    if File.dir?(project_path) do
      apps = scan_dir(project_path, max_depth)
      Enum.sort_by(apps, &elem(&1, 0))
    else
      []
    end
  end

  # Depth 0 means "just this directory, no recursion".
  defp scan_dir(dir, depth_remaining) do
    here = parse_fly_toml(dir)

    if depth_remaining <= 0 do
      here
    else
      nested =
        dir
        |> File.ls!()
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.flat_map(&scan_dir(&1, depth_remaining - 1))

      here ++ nested
    end
  end

  @doc """
  Parse the `app = "..."` line out of a `fly.toml` body.

  Requires the value to be either fully quoted (`app = "my-app"` or
  `app = 'my-app'`) or an unquoted sequence of non-whitespace, non-quote
  characters (`app = my-app`). Values with internal whitespace inside quotes
  are intentionally rejected since Fly app names cannot contain whitespace.
  """
  @spec parse_app_name(String.t()) :: {:ok, String.t()} | :error
  def parse_app_name(content) do
    cond do
      match = Regex.run(~r/^\s*app\s*=\s*"([^"\s]+)"/m, content) -> {:ok, Enum.at(match, 1)}
      match = Regex.run(~r/^\s*app\s*=\s*'([^'\s]+)'/m, content) -> {:ok, Enum.at(match, 1)}
      match = Regex.run(~r/^\s*app\s*=\s*([^"'\s#]+)/m, content) -> {:ok, Enum.at(match, 1)}
      true -> :error
    end
  end

  @doc """
  Run `fly deploy --remote-only` from `fly_toml_dir` (absolute path or relative
  to `project_path`). 15 min timeout.

  Returns `{:ok, output}` or `{:error, reason}` — see the module docs for the
  full error shape. In particular, a missing `fly` executable returns
  `{:error, {:fly_error, :not_found, _}}`, matching `stream_deploy/3`.
  """
  @spec deploy(String.t(), String.t()) :: {:ok, String.t()} | {:error, deploy_error()}
  def deploy(project_path, fly_toml_dir) do
    deploy_dir = resolve_dir(project_path, fly_toml_dir)

    cond do
      not File.dir?(deploy_dir) ->
        {:error, :invalid_deploy_dir}

      is_nil(System.find_executable("fly")) ->
        Logger.error("[ExAtlas.Fly.Deploy] `fly` executable not found in PATH")
        {:error, {:fly_error, :not_found, "fly executable not found in PATH"}}

      true ->
        Logger.info("[ExAtlas.Fly.Deploy] Running `fly deploy` in #{deploy_dir}")

        task =
          Task.async(fn ->
            System.cmd("fly", ["deploy", "--remote-only"],
              cd: deploy_dir,
              stderr_to_stdout: true
            )
          end)

        case Task.yield(task, @fly_deploy_timeout_ms) || Task.shutdown(task, :brutal_kill) do
          {:ok, {output, 0}} ->
            Logger.info("[ExAtlas.Fly.Deploy] Deploy succeeded")
            {:ok, output}

          {:ok, {output, exit_code}} ->
            Logger.error("[ExAtlas.Fly.Deploy] Deploy failed (exit #{exit_code}): #{output}")
            {:error, {:fly_error, exit_code, output}}

          nil ->
            Logger.error(
              "[ExAtlas.Fly.Deploy] Deploy timed out after #{@fly_deploy_timeout_ms}ms"
            )

            {:error, {:fly_error, :timeout, "Deploy timed out after #{@fly_deploy_timeout_ms}ms"}}
        end
    end
  end

  @doc """
  Run `fly deploy --remote-only` and stream output via `ExAtlas.Fly.Dispatcher`.

  For each non-empty line, broadcasts `{:ex_atlas_fly_deploy, ticket_id, line}`
  on `"ex_atlas_fly_deploy:\#{ticket_id}"`.

  Two timers guard the deploy:

    * Activity timer (default 5 min) — resets on each chunk. Fires if the
      deploy stalls (e.g. builder hang).
    * Absolute timer (default 30 min) — never resets. Caps total deploy time.

  ## Options

    * `:activity_timeout_ms` — override the per-chunk inactivity timeout.
    * `:max_timeout_ms` — override the absolute deploy timeout.
  """
  @spec stream_deploy(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, deploy_error()}
  def stream_deploy(project_path, fly_toml_dir, ticket_id, opts \\ []) do
    deploy_dir = resolve_dir(project_path, fly_toml_dir)

    cond do
      not File.dir?(deploy_dir) ->
        {:error, :invalid_deploy_dir}

      fly_executable = System.find_executable("fly") ->
        Logger.debug("[ExAtlas.Fly.Deploy] Streaming `fly deploy` in #{deploy_dir}")
        stream_deploy_with_fly(fly_executable, deploy_dir, ticket_id, opts)

      true ->
        Logger.error("[ExAtlas.Fly.Deploy] `fly` executable not found in PATH")
        {:error, {:fly_error, :not_found, "fly executable not found in PATH"}}
    end
  end

  defp stream_deploy_with_fly(fly_executable, deploy_dir, ticket_id, opts) do
    activity_timeout = Keyword.get(opts, :activity_timeout_ms, @fly_activity_timeout_ms)
    max_timeout = Keyword.get(opts, :max_timeout_ms, @fly_max_timeout_ms)

    port =
      Port.open({:spawn_executable, fly_executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["deploy", "--remote-only"],
        cd: deploy_dir
      ])

    activity_ref =
      Process.send_after(self(), {:deploy_activity_timeout, port}, activity_timeout)

    absolute_ref =
      Process.send_after(self(), {:deploy_absolute_timeout, port}, max_timeout)

    timers = %{activity: activity_ref, absolute: absolute_ref, port: port}

    {result, final_timers} =
      collect_port_output(port, ticket_id, [], timers, activity_timeout)

    cancel_and_flush(final_timers.activity, {:deploy_activity_timeout, port})
    cancel_and_flush(final_timers.absolute, {:deploy_absolute_timeout, port})

    emit_deploy_exit(ticket_id, result)

    result
  end

  # Public helpers for telemetry — kept alongside the stream so the
  # event contract lives next to the emission point.
  @deploy_line_event [:ex_atlas, :fly, :deploy, :line]
  @deploy_exit_event [:ex_atlas, :fly, :deploy, :exit]

  defp emit_deploy_line(ticket_id) do
    :telemetry.execute(@deploy_line_event, %{count: 1}, %{ticket_id: ticket_id})
  end

  # Normalize the (:ok, _) / (:error, _) return shape into a compact result tag
  # suitable for metric filtering. Line content is never included — Fly build
  # output can contain bearer tokens that must not leak into metrics pipelines.
  defp emit_deploy_exit(ticket_id, {:ok, _output}) do
    :telemetry.execute(@deploy_exit_event, %{}, %{ticket_id: ticket_id, result: :ok})
  end

  defp emit_deploy_exit(ticket_id, {:error, {:fly_error, :timeout, _}}) do
    :telemetry.execute(@deploy_exit_event, %{}, %{
      ticket_id: ticket_id,
      result: {:error, :timeout}
    })
  end

  defp emit_deploy_exit(ticket_id, {:error, {:fly_error, exit_code, _}})
       when is_integer(exit_code) do
    :telemetry.execute(@deploy_exit_event, %{}, %{
      ticket_id: ticket_id,
      result: {:error, {:exit_code, exit_code}}
    })
  end

  # ── Private ──

  defp resolve_dir(project_path, fly_toml_dir) do
    if Path.type(fly_toml_dir) == :absolute do
      fly_toml_dir
    else
      Path.join(project_path, fly_toml_dir)
    end
  end

  defp collect_port_output(port, ticket_id, acc, timers, activity_timeout) do
    receive do
      {^port, {:data, data}} ->
        data
        |> String.split("\n", trim: false)
        |> Enum.each(fn line ->
          if line != "" do
            Dispatcher.dispatch(
              "ex_atlas_fly_deploy:#{ticket_id}",
              {:ex_atlas_fly_deploy, ticket_id, line}
            )

            emit_deploy_line(ticket_id)
          end
        end)

        cancel_and_flush(timers.activity, {:deploy_activity_timeout, port})

        new_activity_ref =
          Process.send_after(self(), {:deploy_activity_timeout, port}, activity_timeout)

        collect_port_output(
          port,
          ticket_id,
          [data | acc],
          %{timers | activity: new_activity_ref},
          activity_timeout
        )

      {^port, {:exit_status, 0}} ->
        output = iodata_to_string(acc)
        Logger.debug("[ExAtlas.Fly.Deploy] Streaming deploy succeeded")
        {{:ok, output}, timers}

      {^port, {:exit_status, exit_code}} ->
        output = iodata_to_string(acc)
        Logger.error("[ExAtlas.Fly.Deploy] Streaming deploy failed (exit #{exit_code})")
        {{:error, {:fly_error, exit_code, output}}, timers}

      {:deploy_activity_timeout, ^port} ->
        safe_port_close(port)
        cancel_and_flush(timers.absolute, {:deploy_absolute_timeout, port})
        output = iodata_to_string(acc)

        Logger.error(
          "[ExAtlas.Fly.Deploy] Streaming deploy stalled (no output for #{activity_timeout}ms)"
        )

        {{:error, {:fly_error, :timeout, output}}, %{timers | activity: nil, absolute: nil}}

      {:deploy_absolute_timeout, ^port} ->
        safe_port_close(port)
        cancel_and_flush(timers.activity, {:deploy_activity_timeout, port})
        output = iodata_to_string(acc)
        Logger.error("[ExAtlas.Fly.Deploy] Streaming deploy hit absolute timeout")
        {{:error, {:fly_error, :timeout, output}}, %{timers | activity: nil, absolute: nil}}
    end
  end

  defp iodata_to_string(acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp safe_port_close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  # nil ref = already cancelled/consumed by a sibling branch — still drain
  # any delivered-but-unconsumed message so it does not leak into the caller's
  # mailbox.
  defp cancel_and_flush(nil, message) do
    receive do
      ^message -> :ok
    after
      0 -> :ok
    end
  end

  defp cancel_and_flush(ref, message) when is_reference(ref) do
    # Process.cancel_timer/1 returns:
    #   - integer (ms remaining) when the timer was still pending — no message queued
    #   - false when the timer already fired — the message MAY be in the mailbox
    case Process.cancel_timer(ref) do
      false ->
        receive do
          ^message -> :ok
        after
          0 -> :ok
        end

      _remaining_ms ->
        :ok
    end
  end

  defp parse_fly_toml(dir) do
    fly_toml_path = Path.join(dir, "fly.toml")

    case File.read(fly_toml_path) do
      {:ok, content} ->
        case parse_app_name(content) do
          {:ok, app_name} -> [{app_name, dir}]
          :error -> []
        end

      {:error, _} ->
        []
    end
  end
end
