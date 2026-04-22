defmodule ExAtlas.Fly.Deploy do
  @moduledoc """
  Discovers Fly.io apps (via `fly.toml`) and runs deploys against them.

  `deploy/2` runs `fly deploy --remote-only` via `System.cmd/3` with a 15 min
  timeout. `stream_deploy/3` uses `Port.open` to stream output line-by-line
  through `ExAtlas.Fly.Dispatcher`, with a 5 min activity timeout and a 30 min
  absolute cap.

  Streamed output lands as `{:ex_atlas_fly_deploy, ticket_id, line}` on the topic
  `"ex_atlas_fly_deploy:\#{ticket_id}"`.
  """

  require Logger

  alias ExAtlas.Fly.Dispatcher

  # Inactivity timeout: reset on each line of output (5 min)
  @fly_activity_timeout_ms 300_000
  # Absolute max deploy time (30 min)
  @fly_max_timeout_ms 1_800_000
  # Non-streaming deploy timeout (15 min)
  @fly_deploy_timeout_ms 900_000

  @doc """
  Scan `project_path` for Fly apps (root `fly.toml` + one level of subdirs).

  Returns a sorted list of `{app_name, directory}` tuples.
  """
  @spec discover_apps(String.t()) :: [{String.t(), String.t()}]
  def discover_apps(project_path) do
    unless File.dir?(project_path) do
      []
    else
      root_apps = parse_fly_toml(project_path)

      sub_apps =
        project_path
        |> File.ls!()
        |> Enum.map(&Path.join(project_path, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.flat_map(&parse_fly_toml/1)

      (root_apps ++ sub_apps)
      |> Enum.sort_by(&elem(&1, 0))
    end
  end

  @doc "Parse the `app = \"...\"` line out of a `fly.toml` body."
  @spec parse_app_name(String.t()) :: {:ok, String.t()} | :error
  def parse_app_name(content) do
    case Regex.run(~r/^app\s*=\s*["']?([^"'\s]+)["']?/m, content) do
      [_, app_name] -> {:ok, app_name}
      _ -> :error
    end
  end

  @doc """
  Run `fly deploy --remote-only` from `fly_toml_dir` (absolute path or relative
  to `project_path`). 15 min timeout. Returns `{:ok, output}` or `{:error, reason}`.
  """
  @spec deploy(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def deploy(project_path, fly_toml_dir) do
    deploy_dir = resolve_dir(project_path, fly_toml_dir)

    unless File.dir?(deploy_dir) do
      {:error, :invalid_deploy_dir}
    else
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
          Logger.error("[ExAtlas.Fly.Deploy] Deploy timed out after #{@fly_deploy_timeout_ms}ms")
          {:error, {:fly_error, :timeout, "Deploy timed out after #{@fly_deploy_timeout_ms}ms"}}
      end
    end
  end

  @doc """
  Run `fly deploy --remote-only` and stream output via `ExAtlas.Fly.Dispatcher`.

  For each non-empty line, broadcasts `{:ex_atlas_fly_deploy, ticket_id, line}`
  on `"ex_atlas_fly_deploy:\#{ticket_id}"`.

  Two timers guard the deploy:

    * Activity timer (5 min) — resets on each chunk. Fires if the deploy
      stalls (e.g. builder hang).
    * Absolute timer (30 min) — never resets. Caps total deploy time.
  """
  @spec stream_deploy(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def stream_deploy(project_path, fly_toml_dir, ticket_id) do
    deploy_dir = resolve_dir(project_path, fly_toml_dir)

    unless File.dir?(deploy_dir) do
      {:error, :invalid_deploy_dir}
    else
      Logger.debug("[ExAtlas.Fly.Deploy] Streaming `fly deploy` in #{deploy_dir}")

      case System.find_executable("fly") do
        nil ->
          Logger.error("[ExAtlas.Fly.Deploy] `fly` executable not found in PATH")
          {:error, {:fly_error, :not_found, "fly executable not found in PATH"}}

        fly_executable ->
          port =
            Port.open({:spawn_executable, fly_executable}, [
              :binary,
              :exit_status,
              :stderr_to_stdout,
              args: ["deploy", "--remote-only"],
              cd: deploy_dir
            ])

          activity_ref =
            Process.send_after(self(), {:deploy_activity_timeout, port}, @fly_activity_timeout_ms)

          absolute_ref =
            Process.send_after(self(), {:deploy_absolute_timeout, port}, @fly_max_timeout_ms)

          {result, final_activity_ref} =
            collect_port_output(port, ticket_id, [], activity_ref, absolute_ref)

          cancel_and_flush(final_activity_ref, {:deploy_activity_timeout, port})
          cancel_and_flush(absolute_ref, {:deploy_absolute_timeout, port})

          result
      end
    end
  end

  # ── Private ──

  defp resolve_dir(project_path, fly_toml_dir) do
    if Path.type(fly_toml_dir) == :absolute do
      fly_toml_dir
    else
      Path.join(project_path, fly_toml_dir)
    end
  end

  defp collect_port_output(port, ticket_id, acc, activity_ref, absolute_ref) do
    receive do
      {^port, {:data, data}} ->
        data
        |> String.split("\n", trim: false)
        |> Enum.each(fn line ->
          unless line == "" do
            Dispatcher.dispatch(
              "ex_atlas_fly_deploy:#{ticket_id}",
              {:ex_atlas_fly_deploy, ticket_id, line}
            )
          end
        end)

        cancel_and_flush(activity_ref, {:deploy_activity_timeout, port})

        new_activity_ref =
          Process.send_after(self(), {:deploy_activity_timeout, port}, @fly_activity_timeout_ms)

        collect_port_output(port, ticket_id, [data | acc], new_activity_ref, absolute_ref)

      {^port, {:exit_status, 0}} ->
        output = acc |> Enum.reverse() |> IO.iodata_to_binary()
        Logger.debug("[ExAtlas.Fly.Deploy] Streaming deploy succeeded")
        {{:ok, output}, activity_ref}

      {^port, {:exit_status, exit_code}} ->
        output = acc |> Enum.reverse() |> IO.iodata_to_binary()
        Logger.error("[ExAtlas.Fly.Deploy] Streaming deploy failed (exit #{exit_code})")
        {{:error, {:fly_error, exit_code, output}}, activity_ref}

      {:deploy_activity_timeout, ^port} ->
        safe_port_close(port)
        output = acc |> Enum.reverse() |> IO.iodata_to_binary()

        Logger.error(
          "[ExAtlas.Fly.Deploy] Streaming deploy stalled (no output for #{@fly_activity_timeout_ms}ms)"
        )

        {{:error, {:fly_error, :timeout, output}}, activity_ref}

      {:deploy_absolute_timeout, ^port} ->
        safe_port_close(port)
        output = acc |> Enum.reverse() |> IO.iodata_to_binary()

        Logger.error(
          "[ExAtlas.Fly.Deploy] Streaming deploy hit absolute timeout (#{@fly_max_timeout_ms}ms)"
        )

        {{:error, {:fly_error, :timeout, output}}, activity_ref}
    end
  end

  defp safe_port_close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp cancel_and_flush(ref, message) do
    case Process.cancel_timer(ref) do
      false ->
        receive do
          ^message -> :ok
        after
          0 -> :ok
        end

      _ ->
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
