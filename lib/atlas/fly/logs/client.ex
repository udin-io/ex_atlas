defmodule Atlas.Fly.Logs.Client do
  @moduledoc """
  HTTP client for the Fly Machines log API.

  Fetches from `GET https://api.machines.dev/v1/apps/{app_name}/logs` and
  parses the NDJSON body into `Atlas.Fly.Logs.LogEntry` structs.

  The base URL is overridable via `config :atlas, :fly, log_endpoint: "..."`
  or the `:base_url` option (useful for Bypass in tests).
  """

  require Logger

  alias Atlas.Fly.Logs.LogEntry
  alias Atlas.Fly.Tokens

  @default_base_url "https://api.machines.dev/v1/apps"
  @default_timeout_ms 10_000

  @doc """
  Fetches logs for `app_name` using `token`.

  ## Options

    * `:region` — filter by Fly region code.
    * `:instance` — filter by machine instance id.
    * `:start_time` — integer nanoseconds-since-epoch, for pagination.
    * `:base_url` — override the endpoint (default: `:atlas, :fly, log_endpoint` or
      `#{@default_base_url}`).
    * `:timeout_ms` — request timeout.
    * `:http_client` — optional `(url, headers) -> {:ok, status, body} | {:error, reason}`
      override. When omitted, uses `Req`.
  """
  @spec fetch_logs(String.t(), String.t(), keyword()) ::
          {:ok, [LogEntry.t()]} | {:error, term()}
  def fetch_logs(app_name, token, opts \\ []) do
    url = build_url(app_name, opts)

    case http_get(url, token, opts) do
      {:ok, 200, body} -> {:ok, parse_ndjson(body)}
      {:ok, status, body} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Fetches logs with a single 401-driven retry.

  If the server returns 401, the token is invalidated, a new one is acquired,
  and the fetch is retried once.

  ## Options

    * `:token_fn` — `(app_name -> {:ok, token} | {:error, reason})`. Defaults to
      `Atlas.Fly.Tokens.get/1`.
    * `:invalidate_fn` — `(app_name -> :ok)`. Defaults to `Atlas.Fly.Tokens.invalidate/1`.
    * All other options pass through to `fetch_logs/3`.
  """
  @spec fetch_logs_with_retry(String.t(), keyword()) ::
          {:ok, [LogEntry.t()]} | {:error, term()}
  def fetch_logs_with_retry(app_name, opts \\ []) do
    {token_fn, opts} = Keyword.pop(opts, :token_fn, &Tokens.get/1)
    {invalidate_fn, opts} = Keyword.pop(opts, :invalidate_fn, &Tokens.invalidate/1)

    case token_fn.(app_name) do
      {:ok, token} ->
        case fetch_logs(app_name, token, opts) do
          {:error, {:http_error, 401, _body}} ->
            invalidate_fn.(app_name)

            case token_fn.(app_name) do
              {:ok, new_token} -> fetch_logs(app_name, new_token, opts)
              {:error, reason} -> {:error, reason}
            end

          other ->
            other
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the next `start_time` cursor value for pagination.

  Given a list of `LogEntry` structs, returns the max timestamp in nanoseconds
  plus 1 (to avoid re-fetching the last entry). Returns `nil` for an empty list.
  """
  @spec next_start_time([LogEntry.t()]) :: non_neg_integer() | nil
  def next_start_time([]), do: nil

  def next_start_time(entries) when is_list(entries) do
    entries
    |> Enum.max_by(& &1.timestamp)
    |> then(& &1.timestamp)
    |> to_nanoseconds()
    |> Kernel.+(1)
  end

  # ── Private ──

  defp build_url(app_name, opts) do
    base = base_url(opts)
    path = "#{base}/#{app_name}/logs"

    case build_query_params(opts) do
      "" -> path
      query -> "#{path}?#{query}"
    end
  end

  defp base_url(opts) do
    opts[:base_url] ||
      Application.get_env(:atlas, :fly, [])[:log_endpoint] ||
      @default_base_url
  end

  defp build_query_params(opts) do
    [:region, :instance, :start_time]
    |> Enum.map(fn key -> {key, Keyword.get(opts, key)} end)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)
    |> URI.encode_query()
  end

  defp http_get(url, token, opts) do
    headers = [{"Authorization", "Bearer #{token}"}]

    case Keyword.get(opts, :http_client) do
      nil -> req_get(url, headers, opts)
      client_fn -> client_fn.(url, headers)
    end
  end

  defp req_get(url, headers, opts) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    case Req.get(url, headers: headers, receive_timeout: timeout, retry: false) do
      {:ok, %Req.Response{status: status, body: body}} ->
        {:ok, status, to_binary(body)}

      {:error, exception} ->
        {:error, exception}
    end
  end

  # Req may decode JSON bodies automatically; for NDJSON we need raw bytes.
  defp to_binary(body) when is_binary(body), do: body
  defp to_binary(body), do: Jason.encode!(body)

  defp parse_ndjson(body) when is_binary(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.reduce([], fn line, acc ->
      case Jason.decode(line) do
        {:ok, json} ->
          [LogEntry.from_json(json) | acc]

        {:error, _} ->
          Logger.debug("[Atlas.Fly.Logs.Client] Skipping malformed NDJSON line: #{inspect(line)}")
          acc
      end
    end)
    |> Enum.reverse()
  end

  defp to_nanoseconds(iso8601_string) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(iso8601_string)
    DateTime.to_unix(datetime, :nanosecond)
  end
end
