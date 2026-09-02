defmodule ExAtlas.Callback.PlugTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias ExAtlas.Callback
  alias ExAtlas.Callback.{Limiter, Token}
  alias ExAtlas.Callback.Plug, as: CallbackPlug
  alias ExAtlas.Orchestrator.ComputeRegistry
  alias ExAtlas.Test.Orchestrator, as: TestOrchestrator

  setup do: TestOrchestrator.start!()

  @opts CallbackPlug.init([])

  defp tracked_task(kinds \\ Callback.kinds()) do
    task = "task-#{System.unique_integer([:positive])}"
    {:ok, _} = Registry.register(ComputeRegistry, {:callback, task}, nil)
    {task, Token.mint(task, kinds)}
  end

  defp post(path, token, body, headers \\ []) do
    :post
    |> conn(path, body)
    |> put_req_header("content-type", "application/json")
    |> then(fn conn ->
      Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    end)
    |> then(fn conn ->
      if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    end)
    |> CallbackPlug.call(@opts)
  end

  describe "the happy path" do
    test "a progress report is accepted and reaches the tracker" do
      {_task, token} = tracked_task()

      conn = post("/progress", token, ~s({"seq":1,"pct":42,"step":"epoch 2"}))

      assert conn.status == 202
      assert_receive {:atlas_callback, :progress, %{"pct" => 42, "seq" => 1}}
    end

    test "a log batch is accepted and reaches the tracker" do
      {_task, token} = tracked_task()

      conn = post("/logs", token, ~s({"seq":7,"lines":["loss 0.4","loss 0.3"]}))

      assert conn.status == 202
      assert_receive {:atlas_callback, :log, %{"lines" => ["loss 0.4", "loss 0.3"]}}
    end

    test "a finish report is accepted and reaches the tracker" do
      {_task, token} = tracked_task()

      conn = post("/finish", token, ~s({"exit_code":0}))

      assert conn.status == 202
      assert_receive {:atlas_callback, :finish, %{exit_code: 0}}
    end

    test "the response body never echoes the token back" do
      {_task, token} = tracked_task()

      conn = post("/progress", token, ~s({"pct":1}))

      refute conn.resp_body =~ token
    end
  end

  describe "401 — authentication" do
    test "no authorization header at all" do
      {_task, _token} = tracked_task()

      assert post("/progress", nil, ~s({"pct":1})).status == 401
    end

    test "a forged token" do
      {_task, _token} = tracked_task()
      forged = Token.mint("task-1", [:progress], secret: String.duplicate("forgery", 8))

      assert post("/progress", forged, ~s({"pct":1})).status == 401
    end

    test "a garbage bearer value" do
      assert post("/progress", "abcdef", ~s({"pct":1})).status == 401
    end

    test "an expired token" do
      task = "task-#{System.unique_integer([:positive])}"
      {:ok, _} = Registry.register(ComputeRegistry, {:callback, task}, nil)

      stale =
        Token.mint(task, [:progress], max_age: 60, signed_at: System.os_time(:second) - 3_600)

      assert post("/progress", stale, ~s({"pct":1})).status == 401
    end

    test "a token minted without the finish kind cannot report finish" do
      {_task, token} = tracked_task([:progress])

      assert post("/finish", token, ~s({"exit_code":0})).status == 401
      refute_receive {:atlas_callback, :finish, _}
    end

    test "a nonstandard authorization scheme is refused" do
      {_task, token} = tracked_task()

      conn =
        :post
        |> conn("/progress", ~s({"pct":1}))
        |> put_req_header("authorization", "Basic " <> token)
        |> CallbackPlug.call(@opts)

      assert conn.status == 401
    end
  end

  describe "410 — the task is gone" do
    test "a valid token for a task nothing is tracking" do
      token = Token.mint("task-that-ended", Callback.kinds())

      assert post("/progress", token, ~s({"pct":1})).status == 410
    end
  end

  describe "413 — body caps" do
    test "an oversized progress body is refused without being decoded" do
      {_task, token} = tracked_task()
      oversized = ~s({"blob":") <> String.duplicate("x", Callback.body_limit(:progress)) <> ~s("})

      conn = post("/progress", token, oversized)

      assert conn.status == 413
      refute_receive {:atlas_callback, :progress, _}
    end

    test "logs get a looser cap than progress does" do
      {_task, token} = tracked_task()
      middling = String.duplicate("x", Callback.body_limit(:progress) * 2)

      assert post("/progress", token, ~s({"blob":"#{middling}"})).status == 413
      assert post("/logs", token, ~s({"blob":"#{middling}"})).status == 202
    end

    test "a body right at the cap still gets through" do
      {_task, token} = tracked_task()
      envelope = byte_size(~s({"blob":""}))
      filler = String.duplicate("x", Callback.body_limit(:progress) - envelope)

      assert post("/progress", token, ~s({"blob":"#{filler}"})).status == 202
    end

    test "a lying content-length header does not raise the cap" do
      {_task, token} = tracked_task()
      oversized = String.duplicate("x", Callback.body_limit(:progress) + 1)

      conn = post("/progress", token, ~s({"blob":"#{oversized}"}), [{"content-length", "12"}])

      assert conn.status == 413
    end
  end

  describe "429 — rate limits" do
    test "a pod that floods progress is throttled, and only for progress" do
      {_task, token} = tracked_task()

      for _ <- 1..Limiter.burst(:progress) do
        assert post("/progress", token, ~s({"pct":1})).status == 202
      end

      assert post("/progress", token, ~s({"pct":1})).status == 429
      assert post("/logs", token, ~s({"lines":[]})).status == 202
    end

    test "one pod's flood does not throttle another" do
      {_a, token_a} = tracked_task()
      {_b, token_b} = tracked_task()

      for _ <- 1..Limiter.burst(:progress),
          do: post("/progress", token_a, ~s({"pct":1}))

      assert post("/progress", token_a, ~s({"pct":1})).status == 429
      assert post("/progress", token_b, ~s({"pct":1})).status == 202
    end

    test "a rate-limited request never reaches the tracker" do
      {_task, token} = tracked_task()

      for _ <- 1..Limiter.burst(:progress),
          do: post("/progress", token, ~s({"pct":1}))

      flush()
      assert post("/progress", token, ~s({"pct":2})).status == 429
      refute_receive {:atlas_callback, :progress, _}
    end
  end

  describe "400 and 404 — malformed requests" do
    test "a body that is not JSON" do
      {_task, token} = tracked_task()

      assert post("/progress", token, "not json at all").status == 400
    end

    test "a JSON scalar where an object was expected" do
      {_task, token} = tracked_task()

      assert post("/progress", token, "42").status == 400
    end

    test "a finish with no exit code" do
      {_task, token} = tracked_task()

      assert post("/finish", token, ~s({})).status == 400
    end

    test "an unknown sub-path" do
      {_task, token} = tracked_task()

      assert post("/nope", token, ~s({})).status == 404
    end

    test "a GET is not a callback" do
      {_task, token} = tracked_task()

      conn =
        :get
        |> conn("/progress")
        |> put_req_header("authorization", "Bearer " <> token)
        |> CallbackPlug.call(@opts)

      assert conn.status == 404
    end
  end

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end
end
