defmodule Mix.Tasks.ExAtlas.InstallTest do
  use ExUnit.Case, async: true

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
    |> Enum.filter(&String.starts_with?(&1, "priv/repo/migrations/"))
  end

  defp ex_atlas_config(igniter, file \\ "config/config.exs") do
    file
    |> Config.Reader.eval!(content(igniter, file), env: :dev)
    |> Keyword.get(:ex_atlas, [])
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

    test "warns about a start_orchestrator: true in another config file and leaves it" do
      runtime = """
      import Config
      config :ex_atlas, start_orchestrator: true
      """

      igniter = install_ecto(Map.put(host(), "config/runtime.exs", runtime))

      assert_has_warning(igniter, &(&1 =~ "config/runtime.exs" and &1 =~ "start_orchestrator"))
      assert content(igniter, "config/runtime.exs") == runtime
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

      assert_has_issue(igniter, &(&1 =~ "Test.Missing"))
    end

    test "stops on a store other than ecto" do
      igniter = IgniterProject.run("ex_atlas.install", ["--tracking-store", "redis"], host())

      assert_has_issue(igniter, &(&1 =~ "redis" and &1 =~ "ecto"))
    end
  end

  describe "without --tracking-store" do
    test "writes no migration, no orchestrator config and no child" do
      igniter = install(host())

      assert migrations(igniter) == []
      refute content(igniter, "config/config.exs") =~ @store
      refute content(igniter, "config/config.exs") =~ "start_orchestrator"
      assert_unchanged(igniter, "lib/test/application.ex")
    end
  end
end
