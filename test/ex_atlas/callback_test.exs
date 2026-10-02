defmodule ExAtlas.CallbackTest do
  use ExUnit.Case, async: false

  alias ExAtlas.Callback
  alias ExAtlas.Callback.Token
  alias ExAtlas.Orchestrator.ComputeRegistry
  alias ExAtlas.Test.Orchestrator, as: TestOrchestrator

  setup do: TestOrchestrator.start!()

  defp task_id, do: "task-#{System.unique_integer([:positive])}"

  defp register(task_id, attempt \\ 0),
    do: Registry.register(ComputeRegistry, {:callback, task_id}, attempt)

  describe "verify/1" do
    test "accepts a token minted against the configured secret" do
      task = task_id()
      token = Token.mint(task, Callback.kinds())

      assert {:ok, %{task_id: ^task}} = Callback.verify(token)
    end

    test "rejects a token minted against a different secret" do
      token = Token.mint("t", [:progress], secret: String.duplicate("elsewhere", 8))

      assert {:error, :invalid} = Callback.verify(token)
    end

    test "rejects a missing token without raising" do
      assert {:error, :invalid} = Callback.verify(nil)
    end
  end

  describe "ingest/3" do
    test "delivers the payload to the process tracking that task" do
      task = task_id()
      {:ok, _} = register(task)

      assert :ok = Callback.ingest(task, :progress, %{"pct" => 42})

      assert_receive {:atlas_callback, :progress, %{"pct" => 42}}
    end

    test "an untracked task is gone, not an error to shout about" do
      assert {:error, :not_tracked} = Callback.ingest(task_id(), :progress, %{})
    end

    test "a task whose tracker has died is untracked again" do
      task = task_id()
      test_pid = self()

      owner = spawn(fn -> hold(task, test_pid) end)
      assert_receive :registered
      ref = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^owner, :killed}

      assert {:error, :not_tracked} = Callback.ingest(task, :progress, %{})
    end

    test "never blocks on the tracker — a wedged process still answers immediately" do
      task = task_id()

      # A process that registers and then never handles a message at all. With
      # a `GenServer.call` this would hang for the full call timeout; the web
      # request must never be able to park on the orchestrator's mailbox.
      test_pid = self()
      _wedged = spawn_link(fn -> hold(task, test_pid) end)
      assert_receive :registered

      assert :ok = Callback.ingest(task, :progress, %{"pct" => 1})
    end

    test "a payload that is not a JSON object is refused" do
      task = task_id()
      {:ok, _} = register(task)

      assert {:error, :invalid_payload} = Callback.ingest(task, :progress, [1, 2, 3])
      assert {:error, :invalid_payload} = Callback.ingest(task, :log, "a string")
    end
  end

  describe "finish payloads" do
    setup do
      task = task_id()
      {:ok, _} = register(task)
      %{task: task}
    end

    test "a clean exit is recorded as exit code 0", %{task: task} do
      assert :ok = Callback.ingest(task, :finish, %{"exit_code" => 0})
      assert_receive {:atlas_callback, :finish, %{exit_code: 0}}
    end

    test "a signal-shaped exit code is accepted", %{task: task} do
      assert :ok = Callback.ingest(task, :finish, %{"exit_code" => 137})
      assert_receive {:atlas_callback, :finish, %{exit_code: 137}}
    end

    test "a finish with no exit code is refused", %{task: task} do
      assert {:error, :invalid_payload} = Callback.ingest(task, :finish, %{})
    end

    test "an exit code outside a shell's range is refused", %{task: task} do
      assert {:error, :invalid_payload} = Callback.ingest(task, :finish, %{"exit_code" => 256})
      assert {:error, :invalid_payload} = Callback.ingest(task, :finish, %{"exit_code" => -1})
    end

    test "a non-integer exit code is refused rather than coerced", %{task: task} do
      assert {:error, :invalid_payload} = Callback.ingest(task, :finish, %{"exit_code" => "0"})
      assert {:error, :invalid_payload} = Callback.ingest(task, :finish, %{"exit_code" => nil})
    end
  end

  describe "body_limit/1" do
    test "logs get the loosest cap and the other two the tight one" do
      assert Callback.body_limit(:progress) == 8 * 1024
      assert Callback.body_limit(:finish) == 8 * 1024
      assert Callback.body_limit(:log) == 64 * 1024
    end
  end

  describe "kind_from_path/1" do
    test "maps the three documented paths and nothing else" do
      assert {:ok, :progress} = Callback.kind_from_path(["progress"])
      assert {:ok, :log} = Callback.kind_from_path(["logs"])
      assert {:ok, :finish} = Callback.kind_from_path(["finish"])

      assert :error = Callback.kind_from_path(["progres"])
      assert :error = Callback.kind_from_path([])
      assert :error = Callback.kind_from_path(["progress", "extra"])
    end
  end

  describe "prepare/1" do
    test "opts with no callback come back untouched" do
      opts = [provider: :mock, gpu: :h100]

      assert {:ok, ^opts} = Callback.prepare(opts)
    end

    test "a callback url becomes a descriptor carrying a fresh task id" do
      {:ok, opts} = Callback.prepare(callback: "https://app.example.com/atlas/cb")

      assert %{url: "https://app.example.com/atlas/cb", task_id: task_id, kinds: kinds} =
               opts[:callback]

      assert is_binary(task_id)
      assert kinds == Callback.kinds()
    end

    test "each prepare mints a distinct task id" do
      {:ok, a} = Callback.prepare(callback: "https://app.example.com/cb")
      {:ok, b} = Callback.prepare(callback: "https://app.example.com/cb")

      refute a[:callback].task_id == b[:callback].task_id
    end

    test "an already-prepared descriptor survives re-preparation unchanged" do
      {:ok, first} = Callback.prepare(callback: "https://app.example.com/cb")
      {:ok, again} = Callback.prepare(first)

      assert again[:callback] == first[:callback]
    end

    test "a prepared descriptor with no attempt, as 0.8.0 built it, starts at attempt 0" do
      {:ok, first} = Callback.prepare(callback: "https://app.example.com/cb")
      built_by_0_8_0 = Keyword.update!(first, :callback, &Map.delete(&1, :attempt))

      {:ok, again} = Callback.prepare(built_by_0_8_0)

      assert {:ok, %{attempt: 0}} =
               Callback.verify(Callback.env(again[:callback])["ATLAS_CALLBACK_TOKEN"])
    end

    test "the token expires with the work, not long after it" do
      {:ok, opts} =
        Callback.prepare(callback: "https://app.example.com/cb", max_runtime_ms: 60_000)

      assert opts[:callback].max_age_s > 60
      assert opts[:callback].max_age_s < 3_600
    end

    test "falls back to the configured base url" do
      Application.put_env(:ex_atlas, :callback,
        secret: TestOrchestrator.callback_secret(),
        base_url: "https://configured.example.com/cb"
      )

      {:ok, opts} = Callback.prepare(gpu: :h100)

      assert opts[:callback].url == "https://configured.example.com/cb"
    end

    test "refuses a url the pod could never reach" do
      for url <- [
            "http://app.example.com/cb",
            "https://localhost/cb",
            "https://127.0.0.1:4000/cb",
            "https://192.168.1.10/cb",
            "https://10.0.0.5/cb",
            "https://172.16.4.4/cb",
            "https://[::1]/cb",
            "https://my-laptop.local/cb",
            "/atlas/cb",
            "not a url at all"
          ] do
        assert {:error, {:invalid_callback_url, _}} = Callback.prepare(callback: url),
               "expected #{url} to be refused"
      end
    end

    # The pod appends /finish, so a query or a fragment would swallow the
    # path, and userinfo would show in `ps` wherever curl runs.
    test "refuses a url with userinfo, a query or a fragment, even when insecure is allowed" do
      for url <- [
            "https://user:secret@app.example.com/cb",
            "https://app.example.com/cb?x=1",
            "https://app.example.com/cb#part"
          ],
          insecure <- [false, true] do
        assert {:error, {:invalid_callback_url, reason}} =
                 Callback.prepare(callback: url, allow_insecure_callback: insecure),
               "expected #{url} to be refused"

        assert reason in [:has_userinfo, :has_query, :has_fragment]
      end
    end

    test "allow_insecure_callback opens the door for a tunnel-free dev loop" do
      assert {:ok, opts} =
               Callback.prepare(
                 callback: "http://localhost:4000/cb",
                 allow_insecure_callback: true
               )

      assert opts[:callback].url == "http://localhost:4000/cb"
    end

    test "a trailing slash is trimmed so the pod can append /finish" do
      {:ok, opts} = Callback.prepare(callback: "https://app.example.com/atlas/cb/")

      assert opts[:callback].url == "https://app.example.com/atlas/cb"
    end
  end

  describe "ingest/3 with verified claims" do
    test "delivers a report whose attempt is the tracker's current one" do
      task = task_id()
      {:ok, _} = register(task, 1)

      assert :ok = Callback.ingest(%{task_id: task, attempt: 1}, :progress, %{"pct" => 1})
      assert_receive {:atlas_callback, :progress, %{"pct" => 1}, 1}
    end

    test "refuses a report from an earlier attempt as untracked" do
      task = task_id()
      {:ok, _} = register(task, 1)

      assert {:error, :not_tracked} =
               Callback.ingest(%{task_id: task, attempt: 0}, :finish, %{"exit_code" => 0})

      refute_received {:atlas_callback, _, _}
      refute_received {:atlas_callback, _, _, _}
    end

    test "accepts a token with no attempt unchecked, as 0.8.0 minted it" do
      task = task_id()
      {:ok, _} = register(task, 1)

      assert :ok = Callback.ingest(%{task_id: task, attempt: nil}, :finish, %{"exit_code" => 0})
      assert_receive {:atlas_callback, :finish, %{exit_code: 0}}
    end

    test "an untracked task is still gone" do
      assert {:error, :not_tracked} =
               Callback.ingest(%{task_id: task_id(), attempt: 0}, :progress, %{})
    end
  end

  describe "take/2" do
    test "a bare task id and a claim-less token share one bucket" do
      task = task_id()
      claims = %{task_id: task, attempt: nil, kinds: Callback.kinds()}

      for _ <- 1..Callback.Limiter.burst(:log), do: assert(:ok = Callback.take(claims, :log))

      assert {:error, :rate_limited} = Callback.take(task, :log)
    end

    test "each attempt of a task has its own bucket" do
      task = task_id()
      attempt_0 = %{task_id: task, attempt: 0, kinds: Callback.kinds()}
      attempt_1 = %{attempt_0 | attempt: 1}

      for _ <- 1..Callback.Limiter.burst(:log), do: assert(:ok = Callback.take(attempt_0, :log))

      assert {:error, :rate_limited} = Callback.take(attempt_0, :log)
      assert :ok = Callback.take(attempt_1, :log)
      assert :ok = Callback.take(task, :log)
    end
  end

  describe "env/1" do
    test "expands a descriptor into the three documented variables" do
      {:ok, opts} = Callback.prepare(callback: "https://app.example.com/cb")
      config = opts[:callback]

      env = Callback.env(config)

      assert env["ATLAS_CALLBACK_URL"] == "https://app.example.com/cb"
      assert env["ATLAS_TASK_ID"] == config.task_id
      assert {:ok, %{task_id: task_id}} = Callback.verify(env["ATLAS_CALLBACK_TOKEN"])
      assert task_id == config.task_id
    end

    test "a prepared callback's token carries attempt 0" do
      {:ok, opts} = Callback.prepare(callback: "https://app.example.com/cb")

      token = Callback.env(opts[:callback])["ATLAS_CALLBACK_TOKEN"]

      assert {:ok, %{attempt: 0}} = Callback.verify(token)
    end

    test "a callback map with no attempt, as 0.8.0 stored it, mints a token with none" do
      {:ok, opts} = Callback.prepare(callback: "https://app.example.com/cb")
      stored = Map.delete(opts[:callback], :attempt)

      token = Callback.env(stored)["ATLAS_CALLBACK_TOKEN"]

      assert {:ok, %{attempt: nil}} = Callback.verify(token)
    end

    test "the minted token is scoped to that task alone" do
      {:ok, mine} = Callback.prepare(callback: "https://app.example.com/cb")
      {:ok, theirs} = Callback.prepare(callback: "https://app.example.com/cb")

      {:ok, claims} = Callback.verify(Callback.env(mine[:callback])["ATLAS_CALLBACK_TOKEN"])

      refute claims.task_id == theirs[:callback].task_id
    end
  end

  # Registers under the callback key and then never receives anything, so a
  # test can prove the boundary neither blocks on nor calls into the tracker.
  defp hold(task_id, notify) do
    {:ok, _} = register(task_id)
    send(notify, :registered)
    Process.sleep(:infinity)
  end
end
