defmodule ExAtlas.Fly.DeployTest do
  use ExUnit.Case, async: true

  alias ExAtlas.Fly.Deploy

  @tmp_dir "tmp/ex_atlas_fly_deploy_test"

  setup do
    test_dir = Path.join(@tmp_dir, "#{System.unique_integer([:positive])}")
    File.rm_rf!(test_dir)
    File.mkdir_p!(test_dir)

    on_exit(fn -> File.rm_rf!(test_dir) end)

    {:ok, test_dir: test_dir}
  end

  describe "discover_apps/1" do
    test "finds fly.toml at project root", %{test_dir: dir} do
      File.write!(Path.join(dir, "fly.toml"), """
      app = "my-web-app"
      primary_region = "ord"
      """)

      assert [{"my-web-app", ^dir}] = Deploy.discover_apps(dir)
    end

    test "finds fly.toml in subdirectories (monorepo)", %{test_dir: dir} do
      api_dir = Path.join(dir, "api")
      web_dir = Path.join(dir, "web")
      File.mkdir_p!(api_dir)
      File.mkdir_p!(web_dir)

      File.write!(Path.join(api_dir, "fly.toml"), "app = \"my-api\"\n")
      File.write!(Path.join(web_dir, "fly.toml"), "app = \"my-web\"\n")

      apps = Deploy.discover_apps(dir)
      assert length(apps) == 2
      assert Enum.map(apps, &elem(&1, 0)) == ["my-api", "my-web"]
    end

    test "finds fly.toml at both root and subdirectories", %{test_dir: dir} do
      File.write!(Path.join(dir, "fly.toml"), "app = \"root-app\"\n")

      sub_dir = Path.join(dir, "worker")
      File.mkdir_p!(sub_dir)
      File.write!(Path.join(sub_dir, "fly.toml"), "app = \"worker-app\"\n")

      apps = Deploy.discover_apps(dir)
      assert length(apps) == 2
      assert "root-app" in Enum.map(apps, &elem(&1, 0))
      assert "worker-app" in Enum.map(apps, &elem(&1, 0))
    end

    test "returns empty list when no fly.toml files exist", %{test_dir: dir} do
      assert Deploy.discover_apps(dir) == []
    end

    test "returns empty list for nonexistent directory" do
      assert Deploy.discover_apps("/nonexistent/path") == []
    end

    test "does not descend deeper than one level", %{test_dir: dir} do
      deep_dir = Path.join([dir, "level1", "level2"])
      File.mkdir_p!(deep_dir)
      File.write!(Path.join(deep_dir, "fly.toml"), "app = \"deep-app\"\n")

      assert Deploy.discover_apps(dir) == []
    end

    test "results are sorted by app name", %{test_dir: dir} do
      for name <- ["zebra", "alpha", "middle"] do
        sub = Path.join(dir, name)
        File.mkdir_p!(sub)
        File.write!(Path.join(sub, "fly.toml"), "app = \"#{name}-app\"\n")
      end

      apps = Deploy.discover_apps(dir)
      assert Enum.map(apps, &elem(&1, 0)) == ["alpha-app", "middle-app", "zebra-app"]
    end

    test "skips fly.toml files that cannot be parsed", %{test_dir: dir} do
      File.write!(Path.join(dir, "fly.toml"), "app = \"good-app\"\n")

      sub = Path.join(dir, "broken")
      File.mkdir_p!(sub)
      File.write!(Path.join(sub, "fly.toml"), "primary_region = \"ord\"\n")

      assert [{"good-app", _}] = Deploy.discover_apps(dir)
    end

    test "max_depth: 2 descends into apps/<name>/fly.toml monorepo layout", %{test_dir: dir} do
      apps_dir = Path.join([dir, "apps", "api"])
      File.mkdir_p!(apps_dir)
      File.write!(Path.join(apps_dir, "fly.toml"), "app = \"nested-api\"\n")

      # Default (max_depth: 1) doesn't find it.
      assert Deploy.discover_apps(dir) == []

      # max_depth: 2 does.
      assert [{"nested-api", _}] = Deploy.discover_apps(dir, max_depth: 2)
    end

    test "max_depth: 0 only looks at the root dir", %{test_dir: dir} do
      File.write!(Path.join(dir, "fly.toml"), "app = \"root-only\"\n")

      sub = Path.join(dir, "api")
      File.mkdir_p!(sub)
      File.write!(Path.join(sub, "fly.toml"), "app = \"subapp\"\n")

      assert [{"root-only", _}] = Deploy.discover_apps(dir, max_depth: 0)
    end
  end

  describe "parse_app_name/1" do
    test "parses standard fly.toml format" do
      assert Deploy.parse_app_name("app = \"my-app\"\nprimary_region = \"ord\"") ==
               {:ok, "my-app"}
    end

    test "parses with single quotes" do
      assert Deploy.parse_app_name("app = 'my-app'") == {:ok, "my-app"}
    end

    test "parses with extra whitespace" do
      assert Deploy.parse_app_name("app  =  \"my-app\"") == {:ok, "my-app"}
    end

    test "parses app name with no quotes" do
      assert Deploy.parse_app_name("app = my-app") == {:ok, "my-app"}
    end

    test "returns error when no app line found" do
      assert Deploy.parse_app_name("primary_region = \"ord\"") == :error
    end

    test "parses app name from middle of file" do
      content = """
      [build]
      builder = "heroku/buildpacks:20"

      app = "production-app"

      [env]
      PORT = "8080"
      """

      assert Deploy.parse_app_name(content) == {:ok, "production-app"}
    end

    test "rejects quoted value with internal whitespace (L3)" do
      # Pre-L3 fix: returned {:ok, "my"} because the regex stopped at the
      # first whitespace inside the quotes. Fly app names cannot contain
      # whitespace, so the honest answer is :error.
      assert Deploy.parse_app_name(~s(app = "my app")) == :error
    end

    test "ignores trailing comment on unquoted line (L3)" do
      assert Deploy.parse_app_name("app = my-app  # inline comment") == {:ok, "my-app"}
    end
  end

  describe "stream_deploy/3" do
    test "returns error for invalid deploy directory" do
      assert {:error, :invalid_deploy_dir} =
               Deploy.stream_deploy("/nonexistent/path", "/nonexistent/path", "ticket-123")
    end

    test "returns error for relative path to nonexistent dir", %{test_dir: dir} do
      assert {:error, :invalid_deploy_dir} =
               Deploy.stream_deploy(dir, "nonexistent_subdir", "ticket-123")
    end

    test "does not leak timer messages after activity timeout", %{test_dir: dir} do
      # Fake fly that writes nothing and sleeps — will trip the activity timeout.
      abs_dir = Path.expand(dir)
      fake_fly = Path.join(abs_dir, "fly")

      File.write!(fake_fly, """
      #!/bin/sh
      sleep 10
      """)

      File.chmod!(fake_fly, 0o755)

      original_path = System.get_env("PATH")
      System.put_env("PATH", "#{abs_dir}:#{original_path}")
      on_exit(fn -> System.put_env("PATH", original_path) end)

      assert {:error, {:fly_error, :timeout, _}} =
               Deploy.stream_deploy(abs_dir, abs_dir, "ticket-activity-timeout",
                 activity_timeout_ms: 50,
                 max_timeout_ms: 5_000
               )

      # The absolute-timer message must NOT survive in the caller mailbox
      # after the activity-timeout branch fires and cleans up.
      refute_received {:deploy_activity_timeout, _}
      refute_received {:deploy_absolute_timeout, _}
    end

    test "does not leak timer messages after absolute timeout", %{test_dir: dir} do
      # Fake fly that writes continuously (resets activity timer) — will trip the absolute timeout.
      abs_dir = Path.expand(dir)
      fake_fly = Path.join(abs_dir, "fly")

      File.write!(fake_fly, """
      #!/bin/sh
      while true; do echo keepalive; sleep 0.05; done
      """)

      File.chmod!(fake_fly, 0o755)

      original_path = System.get_env("PATH")
      System.put_env("PATH", "#{abs_dir}:#{original_path}")
      on_exit(fn -> System.put_env("PATH", original_path) end)

      assert {:error, {:fly_error, :timeout, _}} =
               Deploy.stream_deploy(abs_dir, abs_dir, "ticket-absolute-timeout",
                 activity_timeout_ms: 5_000,
                 max_timeout_ms: 200
               )

      refute_received {:deploy_activity_timeout, _}
      refute_received {:deploy_absolute_timeout, _}
    end

    test "telemetry (N6c): emits :line per non-empty line and :exit on success", %{test_dir: dir} do
      abs_dir = Path.expand(dir)
      fake_fly = Path.join(abs_dir, "fly")

      # Three non-empty lines + a blank one (which must NOT emit a :line event).
      File.write!(fake_fly, """
      #!/bin/sh
      echo "step 1"
      echo "step 2"
      echo ""
      echo "step 3"
      exit 0
      """)

      File.chmod!(fake_fly, 0o755)

      original_path = System.get_env("PATH")
      System.put_env("PATH", "#{abs_dir}:#{original_path}")
      on_exit(fn -> System.put_env("PATH", original_path) end)

      test_pid = self()

      handler_id = "deploy-ok-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler_id,
        [
          [:ex_atlas, :fly, :deploy, :line],
          [:ex_atlas, :fly, :deploy, :exit]
        ],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      ticket = "ticket-telemetry-ok"

      assert {:ok, _output} = Deploy.stream_deploy(abs_dir, abs_dir, ticket)

      line_event = [:ex_atlas, :fly, :deploy, :line]

      for _ <- 1..3 do
        assert_receive {:telemetry, ^line_event, %{count: 1}, %{ticket_id: ^ticket}}, 2_000
      end

      # No fourth line event for the blank line.
      refute_received {:telemetry, ^line_event, _, _}

      exit_event = [:ex_atlas, :fly, :deploy, :exit]

      assert_receive {:telemetry, ^exit_event, _measurements, exit_meta}, 2_000
      assert exit_meta.ticket_id == ticket
      assert exit_meta.result == :ok
    end

    test "telemetry (N6c): emits :exit with {:error, _} on non-zero exit", %{test_dir: dir} do
      abs_dir = Path.expand(dir)
      fake_fly = Path.join(abs_dir, "fly")

      File.write!(fake_fly, """
      #!/bin/sh
      echo "failing line"
      exit 7
      """)

      File.chmod!(fake_fly, 0o755)

      original_path = System.get_env("PATH")
      System.put_env("PATH", "#{abs_dir}:#{original_path}")
      on_exit(fn -> System.put_env("PATH", original_path) end)

      test_pid = self()
      handler_id = "deploy-fail-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:ex_atlas, :fly, :deploy, :exit],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      ticket = "ticket-fail"
      assert {:error, {:fly_error, 7, _}} = Deploy.stream_deploy(abs_dir, abs_dir, ticket)

      exit_event = [:ex_atlas, :fly, :deploy, :exit]
      assert_receive {:telemetry, ^exit_event, _measurements, meta}, 2_000
      assert meta.ticket_id == ticket
      assert match?({:error, {:exit_code, 7}}, meta.result)
    end

    test "does not leak timer messages into the caller mailbox", %{test_dir: dir} do
      # Create a fake `fly` executable that prints a line and exits 0,
      # then prepend its dir to PATH so System.find_executable/1 picks it up.
      abs_dir = Path.expand(dir)
      fake_fly = Path.join(abs_dir, "fly")

      File.write!(fake_fly, """
      #!/bin/sh
      echo "fake deploy ok"
      exit 0
      """)

      File.chmod!(fake_fly, 0o755)

      original_path = System.get_env("PATH")
      System.put_env("PATH", "#{abs_dir}:#{original_path}")
      on_exit(fn -> System.put_env("PATH", original_path) end)

      assert {:ok, _output} = Deploy.stream_deploy(abs_dir, abs_dir, "ticket-mailbox")

      # After the call returns, no deploy timer messages should remain.
      refute_received {:deploy_activity_timeout, _}
      refute_received {:deploy_absolute_timeout, _}
    end
  end

  describe "deploy/2" do
    test "returns error for invalid deploy directory" do
      assert {:error, :invalid_deploy_dir} =
               Deploy.deploy("/nonexistent/path", "/nonexistent/path")
    end

    test "returns {:error, {:fly_error, :not_found, _}} when fly is not on PATH (M5)",
         %{test_dir: dir} do
      # Point PATH at a dir with no `fly` binary. Pre-M5 this path raised
      # ErlangError from System.cmd; post-M5 it mirrors stream_deploy/3
      # and returns a structured error tuple.
      abs_dir = Path.expand(dir)
      empty_path = Path.join(abs_dir, "empty_path")
      File.mkdir_p!(empty_path)

      original_path = System.get_env("PATH")
      System.put_env("PATH", empty_path)
      on_exit(fn -> System.put_env("PATH", original_path) end)

      assert {:error, {:fly_error, :not_found, _}} = Deploy.deploy(abs_dir, abs_dir)
    end
  end
end
