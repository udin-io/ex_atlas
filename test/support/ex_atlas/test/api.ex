defmodule ExAtlas.Test.Api do
  @moduledoc false
  # A stand-in for a vendor's HTTP API, served through Req's `:plug` option
  # (the same hook `Req.Test` uses), so a test opens no socket.
  #
  # `open/0` returns an `Api` with a host of its own. A test passes
  # `api.base_url` and `plug: &Api.dispatch/1` to the client (`opts/1` does
  # both), registers routes with `stub/4`, `expect/4` and `expect_once/4`, and
  # the checks run when the test exits:
  #
  #   * `expect_once` was called exactly once, `expect` at least once
  #   * no request reached a route nobody registered
  #   * no handler raised, so an assertion inside a handler fails the test even
  #     when the code under test turns the 500 it got into an `{:error, _}`
  #
  # A request is routed by host, then method, then path; `:name` segments match
  # any one segment. Registering a route again replaces the earlier handler.

  defstruct [:host, :base_url]

  @table __MODULE__

  @doc "Create the table the routes live in. Called once from `test_helper.exs`."
  def init do
    :ets.new(@table, [:named_table, :public, :set])
    :ok
  end

  @doc "Open an API with its own host; its checks run when the test exits."
  def open do
    host = "api-#{System.unique_integer([:positive])}.stub.test"
    ExUnit.Callbacks.on_exit({__MODULE__, host}, fn -> check!(host) end)
    %__MODULE__{host: host, base_url: "http://#{host}"}
  end

  @doc "Run the exit checks now and clear them; raises `ExUnit.AssertionError` on a failure."
  def verify!(%__MODULE__{host: host}), do: check!(host)

  @doc "The client options that send a request to `api`."
  def opts(%__MODULE__{} = api), do: [base_url: api.base_url, req_options: [plug: plug()]]

  @doc "The `:plug` option value that routes a request to its `Api`."
  def plug, do: &__MODULE__.dispatch/1

  @doc "Answer `method path` with `fun`, any number of times, including none."
  def stub(%__MODULE__{} = api, method, path, fun), do: register(api, :stub, method, path, fun)

  @doc "Answer `method path` with `fun`; the test fails if no request arrives."
  def expect(%__MODULE__{} = api, method, path, fun),
    do: register(api, :expect, method, path, fun)

  @doc "Answer `method path` with `fun`; the test fails unless exactly one request arrives."
  def expect_once(%__MODULE__{} = api, method, path, fun),
    do: register(api, :expect_once, method, path, fun)

  @doc "Answer every request to `api` with a refused connection."
  def unreachable(%__MODULE__{} = api, reason \\ :econnrefused) do
    :ets.insert(@table, {{:any, api.host}, &Req.Test.transport_error(&1, reason)})
    :ok
  end

  @doc "The requests that reached `method path` so far."
  def count(%__MODULE__{} = api, method, path) do
    case :ets.lookup(@table, {:count, api.host, method, segments(path)}) do
      [{_, n}] -> n
      [] -> 0
    end
  end

  @doc false
  def dispatch(conn) do
    host = conn.host

    case lookup(host, conn.method, conn.path_info) do
      {:ok, any} when is_function(any) ->
        any.(conn)

      {:ok, {kind, key, fun}} ->
        {method, segs} = key
        count_key = {:count, host, method, segs}
        n = :ets.update_counter(@table, count_key, 1, {count_key, 0})

        if kind == :expect_once and n > 1 do
          problem(host, "#{conn.method} #{conn.request_path} was expected once, got #{n}")
          Plug.Conn.send_resp(conn, 500, "")
        else
          run(host, conn, fun)
        end

      :error ->
        problem(host, "unexpected request #{conn.method} #{conn.request_path}")
        Plug.Conn.send_resp(conn, 500, "")
    end
  end

  defp register(api, kind, method, path, fun) do
    segs = segments(path)
    :ets.insert(@table, {{:route, api.host, method, segs}, {kind, {method, segs}, fun}})
    :ets.delete(@table, {:count, api.host, method, segs})
    :ok
  end

  defp lookup(host, method, path_info) do
    case :ets.lookup(@table, {:any, host}) do
      [{_, any}] ->
        {:ok, any}

      [] ->
        @table
        |> :ets.match_object({{:route, host, method, :_}, :_})
        |> Enum.find(fn {{:route, _, _, segs}, _} -> matches?(segs, path_info) end)
        |> case do
          {_, route} -> {:ok, route}
          nil -> :error
        end
    end
  end

  defp matches?(route, actual) when length(route) == length(actual),
    do: route |> Enum.zip(actual) |> Enum.all?(fn {r, a} -> match?(":" <> _, r) or r == a end)

  defp matches?(_route, _actual), do: false

  defp segments(path), do: path |> String.split("/", trim: true)

  defp run(host, conn, fun) do
    conn = fun.(conn)
    if conn.state == :set, do: Plug.Conn.send_resp(conn), else: conn
  catch
    kind, reason ->
      problem(host, "handler failed: " <> Exception.format(kind, reason, __STACKTRACE__))
      Plug.Conn.send_resp(conn, 500, "")
  end

  defp problem(host, message) do
    :ets.insert(@table, {{:problem, host, System.unique_integer()}, message})
  end

  defp check!(host) do
    problems =
      for {{:problem, ^host, _}, message} <- :ets.tab2list(@table), do: message

    unmet =
      for {{:route, ^host, method, segs}, {kind, _, _}} <- :ets.tab2list(@table),
          kind in [:expect, :expect_once],
          :ets.lookup(@table, {:count, host, method, segs}) == [],
          do: "#{method} /#{Enum.join(segs, "/")} was expected but never requested"

    for entry <- :ets.tab2list(@table), host_of(entry) == host do
      :ets.delete(@table, elem(entry, 0))
    end

    case problems ++ unmet do
      [] -> :ok
      all -> raise ExUnit.AssertionError, message: Enum.join(all, "\n")
    end
  end

  defp host_of({{_tag, host}, _}), do: host
  defp host_of({{_tag, host, _, _}, _}), do: host
  defp host_of({{_tag, host, _}, _}), do: host
end
