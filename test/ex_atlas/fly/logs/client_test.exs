defmodule ExAtlas.Fly.Logs.ClientTest do
  use ExUnit.Case, async: true

  alias ExAtlas.Fly.Logs.{Client, LogEntry}

  @valid_ndjson_line ~s|{"timestamp":"2024-01-01T00:00:00Z","fly":{"app":{"instance":"abc123","name":"myapp"},"region":"cdg"},"log":{"level":"info"},"message":"Hello world"}|
  @valid_ndjson_line2 ~s|{"timestamp":"2024-01-01T00:00:01Z","fly":{"app":{"instance":"def456","name":"myapp"},"region":"lax"},"log":{"level":"error"},"message":"Something broke"}|

  describe "LogEntry.from_json/1" do
    test "parses nested Fly API JSON into flat struct" do
      entry =
        LogEntry.from_json(%{
          "timestamp" => "2024-01-01T00:00:00Z",
          "fly" => %{
            "app" => %{"instance" => "abc123", "name" => "myapp"},
            "region" => "cdg"
          },
          "log" => %{"level" => "info"},
          "message" => "Hello world"
        })

      assert entry.timestamp == "2024-01-01T00:00:00Z"
      assert entry.message == "Hello world"
      assert entry.level == "info"
      assert entry.region == "cdg"
      assert entry.instance == "abc123"
      assert entry.app_name == "myapp"
    end

    test "handles missing optional fields gracefully" do
      entry =
        LogEntry.from_json(%{
          "timestamp" => "2024-01-01T00:00:00Z",
          "fly" => %{"app" => %{}},
          "log" => %{},
          "message" => "Minimal entry"
        })

      assert entry.level == nil
      assert entry.region == nil
      assert entry.instance == nil
      assert entry.app_name == nil
    end
  end

  describe "fetch_logs/3" do
    test "parses NDJSON response into LogEntry list" do
      body = @valid_ndjson_line <> "\n" <> @valid_ndjson_line2
      http_client = fn _url, _headers -> {:ok, 200, body} end

      assert {:ok, [%LogEntry{message: "Hello world"}, %LogEntry{message: "Something broke"}]} =
               Client.fetch_logs("myapp", "test-token", http_client: http_client)
    end

    test "includes region and instance query params in URL" do
      test_pid = self()

      http_client = fn url, _headers ->
        send(test_pid, {:url, url})
        {:ok, 200, ""}
      end

      Client.fetch_logs("myapp", "test-token",
        http_client: http_client,
        region: "cdg",
        instance: "abc123"
      )

      assert_receive {:url, url}
      assert url =~ "region=cdg"
      assert url =~ "instance=abc123"
    end

    test "includes start_time query param" do
      test_pid = self()

      http_client = fn url, _headers ->
        send(test_pid, {:url, url})
        {:ok, 200, ""}
      end

      Client.fetch_logs("myapp", "test-token",
        http_client: http_client,
        start_time: 1_704_067_200_000_000_000
      )

      assert_receive {:url, url}
      assert url =~ "start_time=1704067200000000000"
    end

    test "omits nil query params" do
      test_pid = self()

      http_client = fn url, _headers ->
        send(test_pid, {:url, url})
        {:ok, 200, ""}
      end

      Client.fetch_logs("myapp", "test-token", http_client: http_client)

      assert_receive {:url, url}
      refute url =~ "?"
    end

    test "returns error on HTTP failure" do
      http_client = fn _url, _headers -> {:error, :timeout} end

      assert {:error, :timeout} =
               Client.fetch_logs("myapp", "test-token", http_client: http_client)
    end

    test "returns error on non-200 status" do
      http_client = fn _url, _headers -> {:ok, 401, "Unauthorized"} end

      assert {:error, {:http_error, 401, "Unauthorized"}} =
               Client.fetch_logs("myapp", "test-token", http_client: http_client)
    end

    test "skips malformed NDJSON lines" do
      body = @valid_ndjson_line <> "\n" <> "not valid json {{"
      http_client = fn _url, _headers -> {:ok, 200, body} end

      assert {:ok, [entry]} = Client.fetch_logs("myapp", "test-token", http_client: http_client)
      assert entry.message == "Hello world"
    end

    test "returns empty list for empty response" do
      http_client = fn _url, _headers -> {:ok, 200, ""} end

      assert {:ok, []} = Client.fetch_logs("myapp", "test-token", http_client: http_client)
    end
  end

  describe "fetch_logs_with_retry/2" do
    test "returns logs on success without retry" do
      call_count = :counters.new(1, [:atomics])

      http_client = fn _url, _headers ->
        :counters.add(call_count, 1, 1)
        {:ok, 200, @valid_ndjson_line}
      end

      token_fn = fn _app -> {:ok, "test-token"} end
      invalidate_fn = fn _app -> :ok end

      assert {:ok, [%LogEntry{message: "Hello world"}]} =
               Client.fetch_logs_with_retry("myapp",
                 token_fn: token_fn,
                 invalidate_fn: invalidate_fn,
                 http_client: http_client
               )

      assert :counters.get(call_count, 1) == 1
    end

    test "invalidates token and retries once on 401" do
      call_count = :counters.new(1, [:atomics])
      invalidate_count = :counters.new(1, [:atomics])

      http_client = fn _url, _headers ->
        :counters.add(call_count, 1, 1)

        case :counters.get(call_count, 1) do
          1 -> {:ok, 401, "Unauthorized"}
          _ -> {:ok, 200, @valid_ndjson_line}
        end
      end

      token_fn = fn _app -> {:ok, "test-token"} end

      invalidate_fn = fn _app ->
        :counters.add(invalidate_count, 1, 1)
        :ok
      end

      assert {:ok, [%LogEntry{message: "Hello world"}]} =
               Client.fetch_logs_with_retry("myapp",
                 token_fn: token_fn,
                 invalidate_fn: invalidate_fn,
                 http_client: http_client
               )

      assert :counters.get(call_count, 1) == 2
      assert :counters.get(invalidate_count, 1) == 1
    end

    test "returns error when retry also fails with 401" do
      http_client = fn _url, _headers -> {:ok, 401, "Unauthorized"} end
      token_fn = fn _app -> {:ok, "test-token"} end
      invalidate_fn = fn _app -> :ok end

      assert {:error, {:http_error, 401, "Unauthorized"}} =
               Client.fetch_logs_with_retry("myapp",
                 token_fn: token_fn,
                 invalidate_fn: invalidate_fn,
                 http_client: http_client
               )
    end

    test "does not retry on non-401 errors" do
      call_count = :counters.new(1, [:atomics])

      http_client = fn _url, _headers ->
        :counters.add(call_count, 1, 1)
        {:ok, 500, "Internal Server Error"}
      end

      token_fn = fn _app -> {:ok, "test-token"} end
      invalidate_fn = fn _app -> :ok end

      assert {:error, {:http_error, 500, "Internal Server Error"}} =
               Client.fetch_logs_with_retry("myapp",
                 token_fn: token_fn,
                 invalidate_fn: invalidate_fn,
                 http_client: http_client
               )

      assert :counters.get(call_count, 1) == 1
    end

    test "returns error when no token available" do
      token_fn = fn _app -> {:error, :no_token_available} end
      invalidate_fn = fn _app -> :ok end

      assert {:error, :no_token_available} =
               Client.fetch_logs_with_retry("myapp",
                 token_fn: token_fn,
                 invalidate_fn: invalidate_fn
               )
    end
  end

  describe "next_start_time/1" do
    test "returns latest timestamp + 1 nanosecond" do
      entries = [
        %LogEntry{timestamp: "2024-01-01T00:00:00Z"},
        %LogEntry{timestamp: "2024-01-01T00:00:02Z"},
        %LogEntry{timestamp: "2024-01-01T00:00:01Z"}
      ]

      assert Client.next_start_time(entries) == 1_704_067_202_000_000_001
    end

    test "returns nil for empty list" do
      assert Client.next_start_time([]) == nil
    end

    test "ignores entries with nil timestamp" do
      entries = [
        %LogEntry{timestamp: nil},
        %LogEntry{timestamp: "2024-01-01T00:00:02Z"},
        %LogEntry{timestamp: nil}
      ]

      assert Client.next_start_time(entries) == 1_704_067_202_000_000_001
    end

    test "returns nil when all timestamps are nil" do
      entries = [%LogEntry{timestamp: nil}, %LogEntry{timestamp: nil}]
      assert Client.next_start_time(entries) == nil
    end

    test "ignores entries with malformed ISO-8601 timestamp" do
      entries = [
        %LogEntry{timestamp: "not-a-date"},
        %LogEntry{timestamp: "2024-01-01T00:00:02Z"}
      ]

      assert Client.next_start_time(entries) == 1_704_067_202_000_000_001
    end

    test "returns nil when all timestamps are malformed" do
      entries = [%LogEntry{timestamp: "nope"}, %LogEntry{timestamp: "also-nope"}]
      assert Client.next_start_time(entries) == nil
    end
  end

  describe "telemetry (N6b)" do
    @fetch_event [:ex_atlas, :fly, :logs, :fetch]

    defp attach_fetch_telemetry(id) do
      test_pid = self()

      handler = fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end

      :telemetry.attach_many(
        id,
        [@fetch_event ++ [:start], @fetch_event ++ [:stop], @fetch_event ++ [:exception]],
        handler,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)
    end

    test "emits :start + :stop with count and status=:ok on success" do
      attach_fetch_telemetry("fetch-ok-#{System.unique_integer([:positive])}")

      body = @valid_ndjson_line <> "\n" <> @valid_ndjson_line2
      http_client = fn _url, _headers -> {:ok, 200, body} end

      assert {:ok, entries} =
               Client.fetch_logs("myapp", "tok", http_client: http_client)

      start_event = @fetch_event ++ [:start]
      stop_event = @fetch_event ++ [:stop]

      assert_receive {:telemetry, ^start_event, _measurements, %{app: "myapp"}}, 500
      assert_receive {:telemetry, ^stop_event, %{duration: _}, meta}, 500
      assert meta.app == "myapp"
      assert meta.status == :ok
      assert meta.count == length(entries)
    end

    test "emits :stop with status={:error, _} and count=0 on HTTP error" do
      attach_fetch_telemetry("fetch-http-err-#{System.unique_integer([:positive])}")

      http_client = fn _url, _headers -> {:ok, 500, "boom"} end

      assert {:error, _} =
               Client.fetch_logs("myapp", "tok", http_client: http_client)

      stop_event = @fetch_event ++ [:stop]

      assert_receive {:telemetry, ^stop_event, _measurements, meta}, 500
      assert match?({:error, _}, meta.status)
      assert meta.count == 0
    end

    test "emits :stop with status={:error, _} on transport error" do
      attach_fetch_telemetry("fetch-transport-err-#{System.unique_integer([:positive])}")

      http_client = fn _url, _headers -> {:error, :timeout} end

      assert {:error, :timeout} =
               Client.fetch_logs("myapp", "tok", http_client: http_client)

      stop_event = @fetch_event ++ [:stop]

      assert_receive {:telemetry, ^stop_event, _measurements, meta}, 500
      assert meta.status == {:error, :timeout}
      assert meta.count == 0
    end
  end
end
