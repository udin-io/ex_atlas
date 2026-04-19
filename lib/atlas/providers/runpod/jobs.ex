defmodule Atlas.Providers.RunPod.Jobs do
  @moduledoc """
  Serverless job operations against `api.runpod.ai/v2/<endpoint>`.

  Supports `/run` (async), `/runsync` (sync, ~90s cap), `/status/:id`,
  `/cancel/:id`, and streaming via `/stream/:id`.
  """

  alias Atlas.Providers.RunPod.Client

  @doc "Async job submission — POST /<endpoint>/run."
  def run(ctx, endpoint_id, body) do
    ctx
    |> Client.runtime(endpoint_id)
    |> Req.post(url: "/run", json: body)
    |> Client.handle_response()
  end

  @doc """
  Synchronous job submission — POST /<endpoint>/runsync.

  RunPod caps runsync at ~90 seconds server-side. We wrap in `Task.async` +
  `Task.yield/shutdown` to guarantee we never block a caller past `timeout_ms`.
  """
  def run_sync(ctx, endpoint_id, body, timeout_ms \\ 90_000) do
    task =
      Task.async(fn ->
        ctx
        |> Client.runtime(endpoint_id)
        |> Req.post(url: "/runsync", json: body, receive_timeout: timeout_ms)
        |> Client.handle_response()
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      nil ->
        {:error,
         Atlas.Error.new(:timeout,
           provider: :runpod,
           message: "runsync exceeded #{timeout_ms}ms"
         )}
    end
  end

  @doc "GET /<endpoint>/status/:job_id — fetch job status."
  def status(ctx, endpoint_id, job_id) do
    ctx
    |> Client.runtime(endpoint_id)
    |> Req.get(url: "/status/#{job_id}")
    |> Client.handle_response()
  end

  @doc "POST /<endpoint>/cancel/:job_id — cancel an in-flight job."
  def cancel(ctx, endpoint_id, job_id) do
    ctx
    |> Client.runtime(endpoint_id)
    |> Req.post(url: "/cancel/#{job_id}")
    |> Client.handle_response()
  end

  @doc """
  Stream partial results — GET /<endpoint>/stream/:job_id.

  Returns a `Stream` that polls the stream endpoint with jittered backoff until
  the job reaches a terminal state.
  """
  def stream(ctx, endpoint_id, job_id) do
    Stream.resource(
      fn -> {ctx, endpoint_id, job_id, 500} end,
      fn {ctx, endpoint_id, job_id, backoff} ->
        case fetch_stream_chunk(ctx, endpoint_id, job_id) do
          {:halt, _} ->
            {:halt, nil}

          {:items, items, :continue} ->
            Process.sleep(jitter(backoff))
            {items, {ctx, endpoint_id, job_id, min(backoff * 2, 5_000)}}

          {:items, items, :terminal} ->
            {items, {ctx, endpoint_id, job_id, :terminal}}
        end
      end,
      fn _ -> :ok end
    )
  end

  defp fetch_stream_chunk(ctx, endpoint_id, job_id) do
    case ctx
         |> Client.runtime(endpoint_id)
         |> Req.get(url: "/stream/#{job_id}")
         |> Client.handle_response() do
      {:ok, %{"status" => "COMPLETED", "stream" => items}} when is_list(items) ->
        {:items, items, :terminal}

      {:ok, %{"status" => status}} when status in ["FAILED", "CANCELLED", "TIMED_OUT"] ->
        {:halt, status}

      {:ok, %{"stream" => items}} when is_list(items) and items != [] ->
        {:items, items, :continue}

      {:ok, _} ->
        {:items, [], :continue}

      {:error, _err} ->
        {:halt, :error}
    end
  end

  defp jitter(base), do: base + :rand.uniform(div(base, 4) + 1)
end
