defmodule ExAtlas.CallbackTest do
  use ExUnit.Case, async: false

  alias ExAtlas.Callback
  alias ExAtlas.Callback.Token
  alias ExAtlas.Orchestrator.ComputeRegistry
  alias ExAtlas.Test.Orchestrator, as: TestOrchestrator

  setup do: TestOrchestrator.start!()

  defp task_id, do: "task-#{System.unique_integer([:positive])}"

  defp register(task_id), do: Registry.register(ComputeRegistry, {:callback, task_id}, nil)

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
