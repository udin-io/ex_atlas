if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.ExAtlas.Install do
    @shortdoc "Installs ExAtlas — writes sensible config defaults and creates storage dirs."

    @moduledoc """
    Installs ExAtlas into your project.

    Run this once after adding `{:ex_atlas, "~> 0.8"}` to `mix.exs`:

        mix ex_atlas.install

    Or use Igniter's installer entry point, which handles the dep addition too:

        mix igniter.install ex_atlas

    ## What it does

      * Writes `config :ex_atlas, :fly, ...` defaults to `config/config.exs`:
        dispatcher mode (chosen based on whether `phoenix_pubsub` is present),
        DETS storage path under `priv/ex_atlas_fly`, and the Fly sub-tree
        `enabled: true`.
      * Creates `priv/ex_atlas_fly/` so DETS has somewhere to write on first run.
      * Adds `.gitignore` rules for the DETS files (`priv/ex_atlas_fly/*.dets`).

    ## Keep tracking records in your database

        mix ex_atlas.install --tracking-store ecto [--repo MyApp.Repo]

    Sets up `ExAtlas.Orchestrator.TrackingStore.Ecto`, so `persist: true` tasks
    survive a deploy on a machine with no volume:

      * Writes `<timestamp>_add_atlas_tracking.exs` in the repo's migrations
        (`priv/repo/migrations` for `MyApp.Repo`), which calls
        `ExAtlas.Orchestrator.TrackingStore.Ecto.Migration`. A migration
        that already calls it stops a second one.
      * Sets `start_orchestrator: false` and the orchestrator's `tracking_store:`
        and `repo:` in `config/config.exs`. Warns about a
        `start_orchestrator: true` in any other config file.
      * Puts `ExAtlas.Orchestrator.Supervisor` in your application's children,
        right after the repo.

    `--repo` picks the repo when the project has several. With none, or with
    a store other than `ecto`, the task stops and changes nothing.

    Idempotent — re-running is safe; `mix ex_atlas.upgrade` handles version-over-version
    migrations.
    """

    use Igniter.Mix.Task

    alias Igniter.Code.Common
    alias Igniter.Code.Function
    require Function
    alias Igniter.Code.List, as: IgniterList
    alias Igniter.Project.Config
    alias Mix.ExAtlas.OrchestratorConfig
    alias Sourceror.Zipper

    @ecto_store ExAtlas.Orchestrator.TrackingStore.Ecto
    @supervisor ExAtlas.Orchestrator.Supervisor
    @other_config_files ["runtime.exs", "prod.exs", "dev.exs", "test.exs"]

    @impl Igniter.Mix.Task
    def info(_argv, _parent) do
      %Igniter.Mix.Task.Info{
        group: :ex_atlas,
        example: "mix ex_atlas.install --tracking-store ecto",
        schema: [tracking_store: :string, repo: :string],
        aliases: []
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      igniter
      |> configure_fly_defaults()
      |> create_storage_dir()
      |> update_gitignore()
      |> install_tracking_store(Keyword.get(igniter.args.options, :tracking_store))
      |> Igniter.add_notice("""
      ExAtlas installed.

      • Run `mix ex_atlas.upgrade` after updating the dep in the future.
      • Fly ops: see `ExAtlas.Fly` or the guide at https://hexdocs.pm/ex_atlas/fly.html.
      • Disable the Fly sub-tree with `config :ex_atlas, :fly, enabled: false`.

      For containerized deploys (Mix releases) where the priv dir is
      read-only, override `storage_path` at runtime in `config/runtime.exs`:

          if System.get_env("ATLAS_FLY_STORAGE_PATH") do
            config :ex_atlas, :fly,
              storage_path: System.get_env("ATLAS_FLY_STORAGE_PATH")
          end

      ExAtlas will fall back to `System.tmp_dir!/0` if the configured
      path is not writable, so a missing env var won't break boot — but
      tokens will not survive container restarts in that case.
      """)
    end

    defp install_tracking_store(igniter, nil), do: igniter

    defp install_tracking_store(igniter, "ecto") do
      case select_repo(igniter) do
        {igniter, {:ok, repo}} ->
          igniter
          |> add_migration(repo)
          |> configure_ecto_store(repo)
          |> add_supervisor_child(repo)
          |> OrchestratorConfig.notice_reap_owner()
          |> Igniter.add_notice("""
          ExAtlas keeps `persist: true` tasks in #{inspect(repo)}. Run `mix ecto.migrate` \
          to create the atlas_tracking_records table. ExAtlas.Orchestrator.Supervisor \
          starts after #{inspect(repo)} in your application's children.
          """)

        {igniter, {:error, message}} ->
          Igniter.add_issue(igniter, message)
      end
    end

    defp install_tracking_store(igniter, other) do
      Igniter.add_issue(
        igniter,
        "Unknown --tracking-store #{inspect(other)}. The one store it installs is `ecto`; " <>
          "leave the option out to keep the DETS default."
      )
    end

    defp select_repo(igniter) do
      {igniter, repos} = Igniter.Libs.Ecto.list_repos(igniter)
      {igniter, pick_repo(Keyword.get(igniter.args.options, :repo), repos)}
    end

    defp pick_repo(nil, []) do
      {:error,
       "mix ex_atlas.install --tracking-store ecto found no Ecto repo in this project. " <>
         "Add a repo, or keep the DETS default."}
    end

    defp pick_repo(nil, [repo]), do: {:ok, repo}

    defp pick_repo(nil, repos) do
      {:error,
       "mix ex_atlas.install --tracking-store ecto found several Ecto repos: " <>
         "#{Enum.map_join(repos, ", ", &inspect/1)}. Pick one with --repo."}
    end

    defp pick_repo(name, repos) do
      repo = Igniter.Project.Module.parse(name)

      if repo in repos do
        {:ok, repo}
      else
        {:error,
         "--repo #{name} is not an Ecto repo in this project. " <>
           "Repos found: #{Enum.map_join(repos, ", ", &inspect/1)}."}
      end
    end

    # Igniter's convention for a repo's migrations: `priv/<last alias
    # segment, underscored>/migrations`.
    defp add_migration(igniter, repo) do
      dir =
        Path.join([
          "priv",
          repo |> Module.split() |> List.last() |> Macro.underscore(),
          "migrations"
        ])

      igniter = Igniter.include_glob(igniter, Path.join(dir, "*.exs"))

      if calls_store_migration?(igniter, dir) do
        igniter
      else
        Igniter.Libs.Ecto.gen_migration(igniter, repo, "add_atlas_tracking",
          body: """
          def up, do: ExAtlas.Orchestrator.TrackingStore.Ecto.Migration.up()
          def down, do: ExAtlas.Orchestrator.TrackingStore.Ecto.Migration.down()
          """,
          on_exists: :skip
        )
      end
    end

    defp configure_ecto_store(igniter, repo) do
      igniter =
        Enum.reduce(
          ["config.exs" | @other_config_files],
          igniter,
          &OrchestratorConfig.include_config/2
        )

      igniter
      |> notice_start_orchestrator()
      |> Config.configure("config.exs", :ex_atlas, [:start_orchestrator], false)
      |> Config.configure("config.exs", :ex_atlas, [:orchestrator, :tracking_store], @ecto_store)
      |> Config.configure("config.exs", :ex_atlas, [:orchestrator, :repo], repo)
      |> warn_start_orchestrator()
    end

    # `ExAtlas.Orchestrator.Supervisor` refuses to start beside
    # `start_orchestrator: true`.
    defp notice_start_orchestrator(igniter) do
      if OrchestratorConfig.sets_start_orchestrator?(igniter, "config.exs", true) do
        Igniter.add_notice(igniter, """
        config/config.exs set `start_orchestrator: true`; the installer set \
        `start_orchestrator: false`. Your app now starts the orchestrator with \
        ExAtlas.Orchestrator.Supervisor, which refuses to start beside the flag.
        """)
      else
        igniter
      end
    end

    # Another file often sets the flag under a condition, so the installer
    # names it instead of editing it.
    defp warn_start_orchestrator(igniter) do
      @other_config_files
      |> Enum.filter(&OrchestratorConfig.sets_start_orchestrator?(igniter, &1, true))
      |> Enum.reduce(igniter, fn file, igniter ->
        Igniter.add_warning(igniter, """
        config/#{file} sets `config :ex_atlas, start_orchestrator: true`. Remove it: \
        ExAtlas.Orchestrator.Supervisor refuses to start beside it.
        """)
      end)
    end

    # `Igniter.Project.Application.add_new_child/3` with `after: [repo]`
    # inserts one place late when another child follows the repo (Igniter
    # 0.8.4's `skip_after/2`), which would start the supervisor after the
    # Endpoint. The installer finds the repo in `children` and inserts right
    # after it.
    defp add_supervisor_child(igniter, repo) do
      app =
        case Igniter.Project.Application.app_module(igniter) do
          {app, _} -> app
          app -> app
        end

      with true <- is_atom(app) and not is_nil(app),
           {:ok, igniter} <-
             Igniter.Project.Module.find_and_update_module(igniter, app, &insert_child(&1, repo)) do
        igniter
      else
        _ -> Igniter.add_warning(igniter, add_child_by_hand(repo))
      end
    end

    defp insert_child(zipper, repo) do
      with {:ok, zipper} <- Function.move_to_def(zipper, :start, 2),
           {:ok, zipper} <-
             Function.move_to_function_call_in_current_scope(zipper, :=, [2], &children?/1),
           {:ok, zipper} <- Function.move_to_nth_argument(zipper, 1),
           {:ok, list} <- children_list(zipper) do
        cond do
          match?({:ok, _}, IgniterList.move_to_list_item(list, &child?(&1, @supervisor))) ->
            {:ok, list}

          match?({:ok, _}, IgniterList.move_to_list_item(list, &child?(&1, repo))) ->
            {:ok, item} = IgniterList.move_to_list_item(list, &child?(&1, repo))
            {:ok, Zipper.insert_right(item, @supervisor)}

          true ->
            {:warning, add_child_by_hand(repo)}
        end
      else
        _ -> {:warning, add_child_by_hand(repo)}
      end
    end

    defp children?(call) do
      Function.argument_matches_pattern?(call, 0, {:children, _, context} when is_atom(context))
    end

    # `children = [...]` or `children = [...] ++ more`.
    defp children_list(zipper) do
      cond do
        IgniterList.list?(zipper) -> {:ok, zipper}
        Function.function_call?(zipper, :++, 2) -> Function.move_to_nth_argument(zipper, 0)
        true -> :error
      end
    end

    # A child is `Module` or `{Module, opts}`; `Common.nodes_equal?/2`
    # expands aliases.
    defp child?(item, module) do
      with true <- Igniter.Code.Tuple.tuple?(item),
           {:ok, first} <- Igniter.Code.Tuple.tuple_elem(item, 0) do
        Common.nodes_equal?(first, module)
      else
        _ -> Common.nodes_equal?(item, module)
      end
    end

    defp add_child_by_hand(repo) do
      "Add ExAtlas.Orchestrator.Supervisor to your application's children, right " <>
        "after #{inspect(repo)}. The installer found no `children = [...]` list " <>
        "holding #{inspect(repo)} in your application's start/2."
    end

    # A host that followed the README by hand named its migration itself.
    defp calls_store_migration?(igniter, dir) do
      Enum.any?(igniter.rewrite, fn source ->
        Path.dirname(Rewrite.Source.get(source, :path)) == dir and
          Rewrite.Source.get(source, :content) =~
            "ExAtlas.Orchestrator.TrackingStore.Ecto.Migration"
      end)
    end

    # Writes default `config :ex_atlas, :fly` block. Each key is only written if
    # it's not already set, so re-running is safe.
    defp configure_fly_defaults(igniter) do
      has_pubsub? = Igniter.Project.Deps.has_dep?(igniter, :phoenix_pubsub)

      igniter =
        igniter
        |> Config.configure(
          "config.exs",
          :ex_atlas,
          [:fly, :enabled],
          true,
          updater: &already_set/1
        )
        |> Config.configure(
          "config.exs",
          :ex_atlas,
          [:fly, :storage_path],
          "priv/ex_atlas_fly",
          updater: &already_set/1
        )

      if has_pubsub? do
        Config.configure(
          igniter,
          "config.exs",
          :ex_atlas,
          [:fly, :dispatcher],
          :phoenix_pubsub,
          updater: &already_set/1
        )
      else
        Config.configure(
          igniter,
          "config.exs",
          :ex_atlas,
          [:fly, :dispatcher],
          :registry,
          updater: &already_set/1
        )
      end
    end

    # `updater` that preserves whatever the user already has.
    defp already_set(zipper), do: {:ok, zipper}

    defp create_storage_dir(igniter) do
      Igniter.mkdir(igniter, "priv/ex_atlas_fly")
    end

    defp gitignore_content(content) do
      if String.contains?(content, "priv/ex_atlas_fly") do
        content
      else
        trailing = if String.ends_with?(content, "\n") or content == "", do: "", else: "\n"

        content <>
          trailing <>
          "\n# ExAtlas DETS token cache\npriv/ex_atlas_fly/*.dets\n"
      end
    end

    defp update_gitignore(igniter) do
      Igniter.update_file(igniter, ".gitignore", fn source ->
        Rewrite.Source.update(source, :content, &gitignore_content(&1 || ""))
      end)
    rescue
      e ->
        # The previous implementation swallowed every exception, so an
        # installer that failed to update .gitignore still reported success
        # and the user could end up committing DETS token files. Surface
        # the failure as an Igniter notice so it is visible in the install
        # output, and tell the user what to add manually.
        Igniter.add_notice(igniter, """
        ExAtlas could not update .gitignore automatically: #{Exception.message(e)}

        Please add the following to your .gitignore manually:

            # ExAtlas DETS token cache
            priv/ex_atlas_fly/*.dets
        """)
    end
  end
else
  defmodule Mix.Tasks.ExAtlas.Install do
    @shortdoc "Installs ExAtlas (requires Igniter)."
    @moduledoc false
    use Mix.Task

    def run(_argv) do
      Mix.raise("""
      mix ex_atlas.install requires `igniter` to be in your deps.

      Add it to your mix.exs:

          {:igniter, "~> 0.6", only: [:dev]}

      Then run `mix deps.get` and retry.

      Alternatively, configure ExAtlas manually:

          # config/config.exs
          config :ex_atlas, :fly,
            enabled: true,
            dispatcher: :registry,
            storage_path: "priv/ex_atlas_fly"
      """)
    end
  end
end
