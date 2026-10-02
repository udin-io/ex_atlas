defmodule Mix.Tasks.ExAtlas.UpgradeTest do
  # Not async: the direct-run test stops and unloads the :ex_atlas application.
  use ExUnit.Case, async: false

  import Igniter.Test

  alias ExAtlas.Test.IgniterProject

  defp upgrade(argv \\ [], files \\ %{}), do: IgniterProject.run("ex_atlas.upgrade", argv, files)

  defp unloaded(fun) do
    :ok = Application.stop(:ex_atlas)
    :ok = Application.unload(:ex_atlas)

    try do
      fun.()
    after
      Application.ensure_all_started(:ex_atlas)
    end
  end

  describe "direct run with no arguments" do
    test "runs the upgraders without the :ex_atlas application loaded" do
      igniter = unloaded(fn -> upgrade() end)

      assert_has_notice(igniter, &(&1 =~ "ExAtlas 0.2 introduces"))
    end

    test "reaches the newest upgrader without the :ex_atlas application loaded" do
      igniter = unloaded(fn -> upgrade() end)

      assert_has_notice(igniter, &(&1 =~ "https://hexdocs.pm/ex_atlas/upgrading.html"))
    end
  end

  describe "0.7.0 to 0.8.0" do
    @guide "https://hexdocs.pm/ex_atlas/upgrading.html"

    defp upgrade_0_7(files \\ %{}), do: upgrade(["0.7.0", "0.8.0"], files)

    defp warnings_naming(igniter, module) do
      Enum.filter(igniter.warnings, &(to_string(&1) =~ module))
    end

    test "warns once per module that implements ExAtlas.Provider" do
      igniter =
        upgrade_0_7(%{
          "lib/my_cloud/provider.ex" => """
          defmodule MyCloud.Provider do
            @behaviour ExAtlas.Provider
          end
          """
        })

      assert [warning] = warnings_naming(igniter, "MyCloud.Provider")
      assert warning =~ "ExAtlas.Secret.reveal/1"
      assert warning =~ "ExAtlas.Config.reveal_req_options/1"
      assert warning =~ @guide
    end

    test "finds the behaviour through an alias, behind another @behaviour" do
      igniter =
        upgrade_0_7(%{
          "lib/my_cloud/provider.ex" => """
          defmodule MyCloud.Provider do
            alias ExAtlas.Provider

            @behaviour GenServer
            @behaviour Provider
          end
          """
        })

      assert [_] = warnings_naming(igniter, "MyCloud.Provider")
    end

    test "finds the behaviour when the process starts under a dot directory" do
      dot_dir =
        Path.join([System.tmp_dir!(), ".ex_atlas_dot_#{System.unique_integer([:positive])}"])

      File.mkdir_p!(dot_dir)

      try do
        igniter =
          File.cd!(dot_dir, fn ->
            upgrade_0_7(%{
              "lib/my_cloud/provider.ex" => """
              defmodule MyCloud.Provider do
                @behaviour ExAtlas.Provider
              end
              """
            })
          end)

        assert [_] = warnings_naming(igniter, "MyCloud.Provider")
      after
        File.rm_rf!(dot_dir)
      end
    end

    test "does not warn about a module that implements only another behaviour" do
      igniter =
        upgrade_0_7(%{
          "lib/my_cloud/worker.ex" => """
          defmodule MyCloud.Worker do
            @behaviour GenServer
          end
          """,
          "lib/my_cloud/other.ex" => """
          defmodule MyCloud.Other do
            alias Some.Other.Provider

            @behaviour Provider
          end
          """
        })

      assert igniter.warnings == []
    end

    test "tells a host with start_orchestrator and no :reap_owner about the reap owner" do
      igniter =
        upgrade_0_7(%{
          "config/config.exs" => """
          import Config
          config :ex_atlas, start_orchestrator: true
          """
        })

      assert_has_notice(igniter, &(&1 =~ ":reap_owner"))
    end

    test "finds start_orchestrator: true inside a runtime.exs block" do
      igniter =
        upgrade_0_7(%{
          "config/runtime.exs" => """
          import Config

          if config_env() == :prod do
            config :ex_atlas, start_orchestrator: true
          end
          """
        })

      assert_has_notice(igniter, &(&1 =~ ":reap_owner"))
    end

    test "stays quiet about the reap owner when runtime.exs sets one" do
      igniter =
        upgrade_0_7(%{
          "config/config.exs" => """
          import Config
          config :ex_atlas, start_orchestrator: true
          """,
          "config/runtime.exs" => """
          import Config
          config :ex_atlas, :orchestrator, reap_owner: System.get_env("FLY_MACHINE_ID")
          """
        })

      refute Enum.any?(igniter.notices, &(&1 =~ ":reap_owner"))
    end

    test "stays quiet about the reap owner when the orchestrator is not started" do
      igniter =
        upgrade_0_7(%{
          "config/config.exs" => """
          import Config
          config :ex_atlas, start_orchestrator: false
          """
        })

      refute Enum.any?(igniter.notices, &(&1 =~ ":reap_owner"))
    end

    test "tells a host that starts ExAtlas.Orchestrator.Supervisor about the reap owner" do
      igniter = upgrade_0_7(IgniterProject.app_with_children("ExAtlas.Orchestrator.Supervisor"))

      assert_has_notice(igniter, &(&1 =~ ":reap_owner"))
    end

    # The alias line names only `ExAtlas.Orchestrator`, so the match needs
    # alias expansion on `Orchestrator.Supervisor`.
    test "finds the supervisor child through an alias" do
      files =
        IgniterProject.app_with_children("Orchestrator.Supervisor",
          alias: "alias ExAtlas.Orchestrator"
        )

      assert_has_notice(upgrade_0_7(files), &(&1 =~ ":reap_owner"))
    end

    test "stays quiet about the reap owner when the host starts the supervisor and sets one" do
      files =
        Map.put(
          IgniterProject.app_with_children("ExAtlas.Orchestrator.Supervisor"),
          "config/runtime.exs",
          """
          import Config
          config :ex_atlas, :orchestrator, reap_owner: System.get_env("FLY_MACHINE_ID")
          """
        )

      refute Enum.any?(upgrade_0_7(files).notices, &(&1 =~ ":reap_owner"))
    end

    test "stays quiet about the reap owner when the application starts other children only" do
      igniter = upgrade_0_7(IgniterProject.app_with_children("Test.Repo"))

      refute Enum.any?(igniter.notices, &(&1 =~ ":reap_owner"))
    end

    test "always links the upgrading guide" do
      assert_has_notice(upgrade_0_7(), &(&1 =~ @guide))
    end

    test "changes no file, so the 0.2 installer step does not run" do
      igniter =
        upgrade_0_7(%{
          "lib/my_cloud/provider.ex" => """
          defmodule MyCloud.Provider do
            @behaviour ExAtlas.Provider
          end
          """
        })

      assert_unchanged(igniter)
      refute Enum.any?(igniter.notices, &(&1 =~ "ExAtlas 0.2 introduces"))
    end
  end
end
