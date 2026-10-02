defmodule ExAtlas.Providers.VastSpendTest do
  # Bypass stands in for Vast's `GET /api/v0/charges/`, shaped by its OpenAPI
  # reference. The real bodies are read by the :vast_live test.
  use ExUnit.Case, async: false

  import ExAtlas.Test.FakeVast

  alias ExAtlas.Spec

  @id "28411907"
  @from ~U[2026-09-21 14:13:20Z]
  @to ~U[2026-09-22 09:00:00Z]
  @marker "label-probe-5e2b"

  setup do
    bypass = Bypass.open()

    opts = [
      provider: :vast,
      api_key: "vast-test-key",
      base_url: "http://localhost:#{bypass.port}",
      from: @from,
      to: @to
    ]

    {:ok, bypass: bypass, opts: opts}
  end

  # Answers each charges request with the next page, after sending the
  # request's query to the test.
  defp charges(bypass, pages) do
    test_pid = self()
    {:ok, remaining} = Agent.start_link(fn -> pages end)

    Bypass.stub(bypass, "GET", "/api/v0/charges", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:charges_query, conn.query_params})

      case Agent.get_and_update(remaining, fn
             [page | rest] -> {page, rest}
             [] -> {nil, []}
           end) do
        {status, body} -> json(conn, status, body)
        nil -> flunk("more charges pages requested than the test gave")
      end
    end)
  end

  defp page(rows, next \\ nil),
    do: {200, %{"success" => true, "results" => rows, "next_token" => next}}

  defp unix(datetime), do: DateTime.to_unix(datetime)

  describe "compute_spend/3" do
    test "sums the instance's rows into total, gpu and disk", %{bypass: bypass, opts: opts} do
      charges(bypass, [
        page([
          charge_row(@id, gpu: 0.6, disk: 0.2, bwd: 0.04, bwu: 0.01),
          charge_row("999", gpu: 50.0, disk: 5.0)
        ])
      ])

      assert {:ok, %Spec.Spend{} = spend} = ExAtlas.compute_spend(@id, opts)

      assert spend.compute_id == @id
      assert spend.provider == :vast
      assert_in_delta spend.total_usd, 0.85, 1.0e-9
      assert_in_delta spend.gpu_usd, 0.6, 1.0e-9
      assert_in_delta spend.disk_usd, 0.2, 1.0e-9
      assert spend.cpu_usd == nil
    end

    test "the total is the rows' amount, which can exceed their items", %{
      bypass: bypass,
      opts: opts
    } do
      row = charge_row(@id, [gpu: 0.6, disk: 0.2], %{"amount" => 1.0})
      charges(bypass, [page([row])])

      assert {:ok, %{total_usd: 1.0, gpu_usd: gpu, disk_usd: disk}} =
               ExAtlas.compute_spend(@id, opts)

      assert_in_delta gpu, 0.6, 1.0e-9
      assert_in_delta disk, 0.2, 1.0e-9
    end

    test "sums every row of the instance across pages and stops at a null token", %{
      bypass: bypass,
      opts: opts
    } do
      charges(bypass, [
        page([charge_row(@id, gpu: 0.5, disk: 0.1)], "page-2"),
        page([charge_row(@id, gpu: 0.25, disk: 0.05)])
      ])

      assert {:ok, spend} = ExAtlas.compute_spend(@id, opts)
      assert_in_delta spend.total_usd, 0.9, 1.0e-9

      assert_received {:charges_query, first}
      assert_received {:charges_query, %{"after_token" => "page-2"}}
      refute_received {:charges_query, _}
      refute Map.has_key?(first, "after_token")
    end

    test "a row of another instance is not counted, even one whose id starts the same", %{
      bypass: bypass,
      opts: opts
    } do
      charges(bypass, [
        page([
          charge_row(@id, gpu: 0.3),
          charge_row("#{@id}0", gpu: 40.0),
          charge_row("1#{@id}", gpu: 40.0),
          charge_row(@id, gpu: 40.0, disk: 1.0, bwd: 0.0) |> Map.put("source", "volume-#{@id}")
        ])
      ])

      assert {:ok, %{total_usd: 0.3}} = ExAtlas.compute_spend(@id, opts)
    end

    test "an instance with no row has a bill of zero", %{bypass: bypass, opts: opts} do
      charges(bypass, [page([charge_row("999", gpu: 7.0)])])

      assert {:ok, %{total_usd: +0.0, gpu_usd: +0.0, disk_usd: +0.0}} =
               ExAtlas.compute_spend(@id, opts)
    end

    test "asks for the instance charges of the UTC days from `from` to `to`", %{
      bypass: bypass,
      opts: opts
    } do
      charges(bypass, [page([])])

      assert {:ok, %{from: from, to: to}} = ExAtlas.compute_spend(@id, opts)

      assert_received {:charges_query, query}
      filters = Jason.decode!(query["select_filters"])
      assert filters["day"]["gte"] == unix(~U[2026-09-21 00:00:00Z])
      assert filters["day"]["lte"] == unix(@to)
      assert filters["type"] == %{"in" => ["instance"]}
      assert query["limit"] == "500"
      assert query["format"] == "table"

      # Vast bills by UTC day, so the window it covers starts at midnight.
      assert from == ~U[2026-09-21 00:00:00Z]
      assert to == @to
    end

    test "with no `to`, the window ends now", %{bypass: bypass, opts: opts} do
      charges(bypass, [page([])])
      before = unix(DateTime.utc_now())

      assert {:ok, %{to: to}} = ExAtlas.compute_spend(@id, Keyword.delete(opts, :to))

      assert_received {:charges_query, query}
      lte = Jason.decode!(query["select_filters"])["day"]["lte"]
      assert lte in before..unix(DateTime.utc_now())
      assert unix(to) == lte
    end

    test "with no `from`, the window starts at the instance's start_date", %{
      bypass: bypass,
      opts: opts
    } do
      Bypass.expect_once(bypass, "GET", "/api/v0/instances/#{@id}", fn conn ->
        json(conn, 200, %{"instances" => instance(%{"start_date" => unix(@from) + 0.5})})
      end)

      charges(bypass, [page([charge_row(@id, gpu: 0.1)])])

      assert {:ok, %{total_usd: 0.1, from: ~U[2026-09-21 00:00:00Z]}} =
               ExAtlas.compute_spend(@id, Keyword.delete(opts, :from))
    end

    test "with no `from` and no such instance, the call is :not_found and reads no charges", %{
      bypass: bypass,
      opts: opts
    } do
      Bypass.expect_once(bypass, "GET", "/api/v0/instances/#{@id}", fn conn ->
        json(conn, 200, %{"instances" => nil})
      end)

      assert {:error, %ExAtlas.Error{kind: :not_found}} =
               ExAtlas.compute_spend(@id, Keyword.delete(opts, :from))
    end

    test "with no `from` and an instance that lists no start_date, the call says to pass one", %{
      bypass: bypass,
      opts: opts
    } do
      Bypass.expect_once(bypass, "GET", "/api/v0/instances/#{@id}", fn conn ->
        json(conn, 200, %{"instances" => instance(%{"start_date" => nil})})
      end)

      assert {:error, %ExAtlas.Error{kind: :validation, message: message}} =
               ExAtlas.compute_spend(@id, Keyword.delete(opts, :from))

      assert message =~ ":from"
    end

    test "a `from` after `to` is :validation, with no request", %{bypass: bypass, opts: opts} do
      Bypass.down(bypass)

      assert {:error, %ExAtlas.Error{kind: :validation}} =
               ExAtlas.compute_spend(@id, Keyword.merge(opts, from: @to, to: @from))
    end
  end

  describe "compute_spend/3 failures" do
    test "a non-advancing token fails the call", %{bypass: bypass, opts: opts} do
      charges(bypass, [
        page([charge_row(@id, gpu: 0.5)], "same"),
        page([charge_row(@id, gpu: 0.5)], "same")
      ])

      assert {:error, %ExAtlas.Error{kind: :provider, message: message}} =
               ExAtlas.compute_spend(@id, opts)

      assert message =~ "did not advance"
    end

    test "a failed second page fails the call, with no partial total", %{
      bypass: bypass,
      opts: opts
    } do
      charges(bypass, [
        page([charge_row(@id, gpu: 0.5)], "page-2"),
        {400, %{"success" => false, "error" => "invalid_token", "msg" => "boom"}}
      ])

      assert {:error, %ExAtlas.Error{kind: :provider, status: 400}} =
               ExAtlas.compute_spend(@id, opts)
    end

    test "the error kinds follow the status", %{bypass: bypass, opts: opts} do
      for {status, kind} <- [{403, :forbidden}, {401, :unauthorized}, {404, :not_found}] do
        charges(bypass, [{status, %{"success" => false, "error" => "auth_error", "msg" => "x"}}])
        assert {:error, %ExAtlas.Error{kind: ^kind}} = ExAtlas.compute_spend(@id, opts)
      end
    end

    test "a body without a results list is :provider and prints none of it", %{
      bypass: bypass,
      opts: opts
    } do
      charges(bypass, [{200, %{"results" => %{"label" => @marker}}}])

      assert {:error, %ExAtlas.Error{kind: :provider} = error} = ExAtlas.compute_spend(@id, opts)
      refute inspect(error, structs: false) =~ @marker
    end

    test "a results entry that is not an object fails the call", %{bypass: bypass, opts: opts} do
      charges(bypass, [page([@marker])])

      assert {:error, %ExAtlas.Error{kind: :provider} = error} = ExAtlas.compute_spend(@id, opts)
      refute inspect(error, structs: false) =~ @marker
    end

    test "a row of the instance with no numeric amount fails the call and prints no row", %{
      bypass: bypass,
      opts: opts
    } do
      row =
        charge_row(@id, [gpu: 0.5], %{"amount" => nil, "items" => [], "description" => @marker})

      charges(bypass, [page([row])])

      assert {:error, %ExAtlas.Error{kind: :provider} = error} = ExAtlas.compute_spend(@id, opts)
      refute inspect(error, structs: false) =~ @marker
    end

    test "a body that is not JSON prints no echo", %{bypass: bypass, opts: opts} do
      Bypass.stub(bypass, "GET", "/api/v0/charges", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(200, ~s({"results":"#{@marker}))
      end)

      assert {:error, %ExAtlas.Error{} = error} = ExAtlas.compute_spend(@id, opts)
      refute inspect(error, structs: false) =~ @marker
    end
  end

  describe "compute_spend/3 raw" do
    test "keeps the amounts and window of the instance's rows, not description or metadata", %{
      bypass: bypass,
      opts: opts
    } do
      row =
        charge_row(@id, [gpu: 0.6, disk: 0.2], %{
          "description" => "Instance #{@id} #{@marker}",
          "metadata" => %{"label" => @marker}
        })

      charges(bypass, [page([row, charge_row("999", gpu: 9.0)])])

      assert {:ok, spend} = ExAtlas.compute_spend(@id, opts)

      # Control: raw holds the amounts, so the refutes below can fail.
      assert [%{"source" => "instance-" <> @id, "amount" => 0.8, "items" => items}] =
               spend.raw["rows"]

      assert [%{"type" => "gpu", "amount" => 0.6}, %{"type" => "disk", "amount" => 0.2}] =
               Enum.map(items, &Map.take(&1, ["type", "amount"]))

      refute inspect(spend, structs: false) =~ @marker
      refute inspect(spend, structs: false) =~ "999"
    end
  end
end
