defmodule Atlas.Fly.DeployTest do
  use ExUnit.Case, async: true

  alias Atlas.Fly.Deploy

  @tmp_dir "tmp/atlas_fly_deploy_test"

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
  end

  describe "deploy/2" do
    test "returns error for invalid deploy directory" do
      assert {:error, :invalid_deploy_dir} =
               Deploy.deploy("/nonexistent/path", "/nonexistent/path")
    end
  end
end
