defmodule Mix.Tasks.ExAtlas.InstallTest do
  # Not async: `IgniterProject.run/3` changes the VM's working directory,
  # and async tests run while ExUnit still loads test files by relative path.
  use ExUnit.Case, async: false

  import Igniter.Test

  alias ExAtlas.Test.IgniterProject

  @entry "priv/ex_atlas_fly/*.dets"
  @migration ~r|^priv/repo/migrations/\d{14}_add_atlas_tracking\.exs$|
  @store "ExAtlas.Orchestrator.TrackingStore.Ecto"

  defp install(files \\ %{}), do: IgniterProject.run("ex_atlas.install", [], files)

  defp install_ecto(files, argv \\ []),
    do: IgniterProject.run("ex_atlas.install", ["--tracking-store", "ecto" | argv], files)

  defp host(children \\ ["Test.Repo"], opts \\ []) do
    IgniterProject.app_with_children(children, Keyword.put_new(opts, :repos, ["Test.Repo"]))
  end

  defp content(igniter, path) do
    if Rewrite.has_source?(igniter.rewrite, path) do
      igniter.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:content)
    end
  end

  defp gitignore(igniter), do: content(igniter, ".gitignore")

  defp migrations(igniter) do
    igniter.rewrite
    |> Enum.map(&Rewrite.Source.get(&1, :path))
    |> Enum.filter(&(&1 =~ ~r|^priv/[^/]+/migrations/|))
  end

  defp ex_atlas_config(igniter, file \\ "config/config.exs") do
    file
    |> Config.Reader.eval!(content(igniter, file), env: :dev)
    |> Keyword.get(:ex_atlas, [])
  end

  # The modules in `children = [...]`, or in the list left of `++`.
  defp children(igniter) do
    {:ok, quoted} = igniter |> content("lib/test/application.ex") |> Code.string_to_quoted()

    {_, children} =
      Macro.prewalk(quoted, nil, fn
        {:=, _, [{:children, _, _}, value]} = node, nil -> {node, child_modules(value)}
        node, acc -> {node, acc}
      end)

    children
  end

  defp child_modules({:++, _, [list, _]}), do: child_modules(list)

  defp child_modules(list) when is_list(list) do
    Enum.map(list, fn
      {module, _opts} -> Macro.to_string(module)
      module -> Macro.to_string(module)
    end)
  end

  describe ".gitignore" do
    test "is created with the DETS entry when the project has none" do
      assert gitignore(install()) =~ @entry
    end

    test "gets a newline before the entry when the file lacks a trailing newline" do
      content = gitignore(install(%{".gitignore" => "/deps"}))

      assert content =~ "/deps\n"
      assert content =~ @entry
    end

    test "stays unchanged when it already names priv/ex_atlas_fly" do
      existing = "/deps\npriv/ex_atlas_fly/\n"

      assert gitignore(install(%{".gitignore" => existing})) == existing
    end
  end

  describe "--tracking-store ecto" do
    test "writes a migration that calls the store's migration module" do
      igniter = install_ecto(host())

      assert [path] = migrations(igniter)
      assert path =~ @migration

      migration = content(igniter, path)
      assert migration =~ "defmodule Test.Repo.Migrations.AddAtlasTracking do"
      assert migration =~ "def up, do: ExAtlas.Orchestrator.TrackingStore.Ecto.Migration.up()"
      assert migration =~ "def down, do: ExAtlas.Orchestrator.TrackingStore.Ecto.Migration.down()"
    end

    test "configures the Ecto store on the repo, with the orchestrator started by the host" do
      config = ex_atlas_config(install_ecto(host()))

      assert config[:start_orchestrator] == false
      assert config[:orchestrator][:tracking_store] == ExAtlas.Orchestrator.TrackingStore.Ecto
      assert config[:orchestrator][:repo] == Test.Repo
    end

    test "keeps the host's other orchestrator settings" do
      files =
        Map.put(host(), "config/config.exs", """
        import Config
        config :ex_atlas, :orchestrator, reap_owner: "web-1", tracking_store: MyApp.OldStore
        """)

      config = ex_atlas_config(install_ecto(files))

      assert config[:orchestrator][:reap_owner] == "web-1"
      assert config[:orchestrator][:tracking_store] == ExAtlas.Orchestrator.TrackingStore.Ecto
    end

    test "starts ExAtlas.Orchestrator.Supervisor after the repo and keeps every other child" do
      igniter =
        install_ecto(host(["TestWeb.Telemetry", "Test.Repo", "TestWeb.Endpoint"]))

      assert children(igniter) == [
               "TestWeb.Telemetry",
               "Test.Repo",
               "ExAtlas.Orchestrator.Supervisor",
               "TestWeb.Endpoint"
             ]
    end

    test "places the child after the repo in the list phx.new generates" do
      phoenix = [
        "TestWeb.Telemetry",
        "Test.Repo",
        "{DNSCluster, query: Application.get_env(:test, :dns_cluster_query) || :ignore}",
        "{Phoenix.PubSub, name: Test.PubSub}",
        "TestWeb.Endpoint"
      ]

      assert children(install_ecto(host(phoenix))) == [
               "TestWeb.Telemetry",
               "Test.Repo",
               "ExAtlas.Orchestrator.Supervisor",
               "DNSCluster",
               "Phoenix.PubSub",
               "TestWeb.Endpoint"
             ]
    end

    test "finds the repo as a {module, opts} child and in a list joined with ++" do
      files =
        Map.put(host(), "lib/test/application.ex", """
        defmodule Test.Application do
          use Application

          @impl true
          def start(_type, _args) do
            children = [{Test.Repo, []}, TestWeb.Endpoint] ++ workers()

            Supervisor.start_link(children, strategy: :one_for_one)
          end

          defp workers, do: []
        end
        """)

      igniter = install_ecto(files)

      assert children(igniter) ==
               ["Test.Repo", "ExAtlas.Orchestrator.Supervisor", "TestWeb.Endpoint"]

      assert content(igniter, "lib/test/application.ex") =~ "] ++ workers()"
    end

    # A host with `start_orchestrator: true` would lose its orchestrator if
    # the installer turned the flag off and added no child.
    test "stops before writing anything when the repo is not in the children" do
      files =
        Map.put(host(["TestWeb.Endpoint"]), "config/config.exs", """
        import Config
        config :ex_atlas, start_orchestrator: true
        """)

      igniter = install_ecto(files)

      assert_has_issue(igniter, &(&1 =~ "ExAtlas.Orchestrator.Supervisor" and &1 =~ "Test.Repo"))
    end

    test "stops when the project has no application module" do
      files = Map.delete(host(), "mix.exs")

      assert_has_issue(install_ecto(files), &(&1 =~ "ExAtlas.Orchestrator.Supervisor"))
    end

    test "writes the migration under the repo's configured priv directory" do
      files =
        Map.put(host(), "config/config.exs", """
        import Config
        config :test, Test.Repo, priv: "priv/db"
        """)

      assert [path] = migrations(install_ecto(files))
      assert path =~ ~r|^priv/db/migrations/\d{14}_add_atlas_tracking\.exs$|
    end

    test "finds a hand-written migration under the repo's configured priv directory" do
      files =
        host()
        |> Map.put("config/config.exs", """
        import Config
        config :test, Test.Repo, priv: "priv/db"
        """)
        |> Map.put("priv/db/migrations/20260101000000_keep_pods.exs", """
        defmodule Test.Repo.Migrations.KeepPods do
          use Ecto.Migration
          def up, do: ExAtlas.Orchestrator.TrackingStore.Ecto.Migration.up()
        end
        """)

      assert migrations(install_ecto(files)) == [
               "priv/db/migrations/20260101000000_keep_pods.exs"
             ]
    end

    test "says which tracking store it replaced" do
      files =
        Map.put(host(), "config/config.exs", """
        import Config
        config :ex_atlas, :orchestrator, tracking_store: ExAtlas.Orchestrator.TrackingStore.Dets
        """)

      assert_has_notice(
        install_ecto(files),
        &(&1 =~ "ExAtlas.Orchestrator.TrackingStore.Dets" and &1 =~ "persist: true")
      )
    end

    test "warns about another tracking store set in another config file" do
      files =
        Map.put(host(), "config/runtime.exs", """
        import Config
        config :ex_atlas, :orchestrator, tracking_store: ExAtlas.Orchestrator.TrackingStore.Dets
        """)

      assert_has_warning(
        install_ecto(files),
        &(&1 =~ "config/runtime.exs" and &1 =~ "tracking_store")
      )
    end

    test "--repo takes a repo built on a wrapper module" do
      files =
        host()
        |> Map.put("lib/test/repo.ex", """
        defmodule Test.Repo do
          use Test.BaseRepo
        end
        """)

      igniter = install_ecto(files, ["--repo", "Test.Repo"])

      assert igniter.issues == []
      assert ex_atlas_config(igniter)[:orchestrator][:repo] == Test.Repo
    end

    test "turns a config.exs start_orchestrator: true off, since the supervisor refuses it" do
      files =
        Map.put(host(), "config/config.exs", """
        import Config
        config :ex_atlas, start_orchestrator: true
        """)

      igniter = install_ecto(files)

      assert ex_atlas_config(igniter)[:start_orchestrator] == false
      assert_has_notice(igniter, &(&1 =~ "start_orchestrator: false"))
    end

    test "turns off a config.exs start_orchestrator given as config/3" do
      files =
        Map.put(host(), "config/config.exs", """
        import Config
        config :ex_atlas, :start_orchestrator, true
        """)

      igniter = install_ecto(files)

      assert ex_atlas_config(igniter)[:start_orchestrator] == false
      assert_has_notice(igniter, &(&1 =~ "start_orchestrator: false"))
    end

    for {name, runtime} <- [
          {"inside an if block",
           """
           import Config

           if config_env() == :prod do
             config :ex_atlas, start_orchestrator: true
           end
           """},
          {"given as config/3",
           """
           import Config
           config :ex_atlas, :start_orchestrator, true
           """}
        ] do
      test "warns about a runtime.exs start_orchestrator: true #{name}" do
        igniter = install_ecto(Map.put(host(), "config/runtime.exs", unquote(runtime)))

        assert_has_warning(
          igniter,
          &(&1 =~ "config/runtime.exs" and &1 =~ "start_orchestrator")
        )
      end
    end

    test "warns about a config.exs start_orchestrator: true inside a block it cannot turn off" do
      files =
        Map.put(host(), "config/config.exs", """
        import Config

        if config_env() == :prod do
          config :ex_atlas, start_orchestrator: true
        end
        """)

      assert_has_warning(
        install_ecto(files),
        &(&1 =~ "config/config.exs" and &1 =~ "start_orchestrator")
      )
    end

    test "warns about a start_orchestrator: true in another config file and leaves it" do
      runtime = """
      import Config
      config :ex_atlas, start_orchestrator: true
      """

      igniter = install_ecto(Map.put(host(), "config/runtime.exs", runtime))

      assert_has_warning(igniter, &(&1 =~ "config/runtime.exs" and &1 =~ "start_orchestrator"))
      assert content(igniter, "config/runtime.exs") == runtime
    end

    test "tells the host to run the migration and set a reap owner" do
      igniter = install_ecto(host())

      assert_has_notice(igniter, &(&1 =~ "mix ecto.migrate"))
      assert_has_notice(igniter, &(&1 =~ ":reap_owner"))
    end

    test "changes nothing on a second run" do
      igniter =
        IgniterProject.in_tmp_dir(fn ->
          [files: host()]
          |> test_project()
          |> Igniter.compose_task("ex_atlas.install", ["--tracking-store", "ecto"])
          |> apply_igniter!()
          |> Igniter.compose_task("ex_atlas.install", ["--tracking-store", "ecto"])
        end)

      assert_unchanged(igniter)
    end

    test "writes no migration when one already calls the store's migration module" do
      files =
        Map.put(host(), "priv/repo/migrations/20260101000000_keep_pods.exs", """
        defmodule Test.Repo.Migrations.KeepPods do
          use Ecto.Migration

          def up, do: ExAtlas.Orchestrator.TrackingStore.Ecto.Migration.up()
          def down, do: ExAtlas.Orchestrator.TrackingStore.Ecto.Migration.down()
        end
        """)

      igniter = install_ecto(files)

      assert migrations(igniter) == ["priv/repo/migrations/20260101000000_keep_pods.exs"]
      assert_unchanged(igniter, "priv/repo/migrations/20260101000000_keep_pods.exs")
    end

    test "--repo picks one of several repos" do
      files = host(["Test.Repo", "Test.ReadRepo"], repos: ["Test.Repo", "Test.ReadRepo"])

      igniter = install_ecto(files, ["--repo", "Test.ReadRepo"])

      assert ex_atlas_config(igniter)[:orchestrator][:repo] == Test.ReadRepo
      assert [path] = migrations(igniter)
      assert path =~ ~r|^priv/read_repo/migrations/\d{14}_add_atlas_tracking\.exs$|
      assert content(igniter, path) =~ "Test.ReadRepo.Migrations.AddAtlasTracking"

      assert children(igniter) ==
               ["Test.Repo", "Test.ReadRepo", "ExAtlas.Orchestrator.Supervisor"]
    end

    test "stops and names the repos when there are several and no --repo" do
      files = host(["Test.Repo", "Test.ReadRepo"], repos: ["Test.Repo", "Test.ReadRepo"])

      igniter = install_ecto(files)

      assert_has_issue(igniter, &(&1 =~ "--repo" and &1 =~ "Test.Repo" and &1 =~ "Test.ReadRepo"))
    end

    test "stops when the project has no Ecto repo" do
      igniter = install_ecto(host(["Test.Worker"], repos: []))

      assert_has_issue(igniter, &(&1 =~ "no Ecto repo"))
    end

    test "stops when --repo names a module that is not a repo" do
      igniter = install_ecto(host(), ["--repo", "Test.Missing"])

      assert_has_issue(igniter, &(&1 =~ "--repo Test.Missing is not an Ecto repo"))
    end

    test "stops on a store other than ecto" do
      igniter = IgniterProject.run("ex_atlas.install", ["--tracking-store", "redis"], host())

      assert_has_issue(igniter, &(&1 =~ "redis" and &1 =~ "ecto"))
    end
  end

  describe "without --tracking-store" do
    test "warns that --repo does nothing alone" do
      igniter = IgniterProject.run("ex_atlas.install", ["--repo", "Test.Repo"], host())

      assert_has_warning(igniter, &(&1 =~ "--repo" and &1 =~ "--tracking-store"))
    end

    test "writes no migration, no orchestrator config and no child" do
      igniter = install(host())

      assert migrations(igniter) == []
      refute content(igniter, "config/config.exs") =~ @store
      refute content(igniter, "config/config.exs") =~ "start_orchestrator"
      assert_unchanged(igniter, "lib/test/application.ex")
    end
  end
end
