if Code.ensure_loaded?(Igniter) do
  defmodule Mix.ExAtlas.OrchestratorConfig do
    @moduledoc false
    # Reads a host project's orchestrator setup for `mix ex_atlas.install` and
    # `mix ex_atlas.upgrade`.

    alias Igniter.Code.Common
    alias Igniter.Code.Function
    alias Igniter.Code.Keyword, as: IgniterKeyword
    alias Igniter.Code.List, as: IgniterList
    alias Sourceror.Zipper

    @guide_url "https://hexdocs.pm/ex_atlas/upgrading.html"
    @config_files ["config.exs", "runtime.exs", "prod.exs"]
    @supervisor {:__aliases__, [], [:ExAtlas, :Orchestrator, :Supervisor]}
    @ecto_store {:__aliases__, [], [:ExAtlas, :Orchestrator, :TrackingStore, :Ecto]}

    @doc """
    Adds a notice when the host starts the orchestrator, with
    `start_orchestrator: true` or `ExAtlas.Orchestrator.Supervisor` in a
    module, and no config file sets `:reap_owner`.
    """
    @spec notice_reap_owner(Igniter.t()) :: Igniter.t()
    def notice_reap_owner(igniter) do
      igniter = Enum.reduce(@config_files, igniter, &include_config/2)
      {igniter, starts?} = starts_orchestrator?(igniter)

      if starts? and not Enum.any?(@config_files, &sets_reap_owner?(igniter, &1)) do
        Igniter.add_notice(igniter, """
        Your app starts the ExAtlas orchestrator and sets no `:reap_owner`. One \
        machine on the account needs nothing. In a cluster, set \
        `config :ex_atlas, :orchestrator, reap_owner: ...` on every node, or no node \
        reaps pods the others spawned. See #{@guide_url}
        """)
      else
        igniter
      end
    end

    @doc """
    Adds a notice when the host starts the orchestrator and no config file sets
    `config :ex_atlas, :callback, secret:`. Without the secret the node signs
    no tracking record, so an adopted task cannot respawn (#131) and adopts
    only a pod the Reaper would delete (#138).
    """
    @spec notice_callback_secret(Igniter.t()) :: Igniter.t()
    def notice_callback_secret(igniter) do
      igniter = Enum.reduce(@config_files, igniter, &include_config/2)
      {igniter, starts?} = starts_orchestrator?(igniter)

      if starts? and not Enum.any?(@config_files, &sets_callback_secret?(igniter, &1)) do
        Igniter.add_notice(igniter, """
        Your app starts the ExAtlas orchestrator and no config file sets \
        `config :ex_atlas, :callback, secret: ...`. Its tracking records are \
        unsigned: an adopted task cannot respawn, and adopts only a pod this \
        node's Reaper would delete. See #{@guide_url}
        """)
      else
        igniter
      end
    end

    @doc """
    Adds a notice when a config file sets the Ecto tracking store: its lease
    table needs migration step 3 before lease rows are signed, and until then
    no owner reads as dead (#148).
    """
    @spec notice_lease_mac(Igniter.t()) :: Igniter.t()
    def notice_lease_mac(igniter) do
      igniter = Enum.reduce(@config_files, igniter, &include_config/2)

      if Enum.any?(@config_files, &sets_ecto_store?(igniter, &1)) do
        Igniter.add_notice(igniter, """
        Your app keeps tracking records in TrackingStore.Ecto. Add a migration calling \
        `ExAtlas.Orchestrator.TrackingStore.Ecto.Migration.up(version: 3)` (and \
        `down(version: 2)`): it adds the `mac` column that signs owner lease rows. \
        Until it runs, lease rows are unsigned and no owner reads as dead. See #{@guide_url}
        """)
      else
        igniter
      end
    end

    defp sets_ecto_store?(igniter, file) do
      igniter
      |> config_values(file, :ex_atlas, [:orchestrator, :tracking_store])
      |> Enum.any?(&Common.nodes_equal?(&1, @ecto_store))
    end

    defp sets_callback_secret?(igniter, file) do
      config_values(igniter, file, :ex_atlas, [:callback, :secret]) != []
    end

    defp starts_orchestrator?(igniter) do
      if Enum.any?(@config_files, &sets_start_orchestrator?(igniter, &1, true)) do
        {igniter, true}
      else
        starts_supervisor?(igniter)
      end
    end

    @doc "Whether any module in the project names `ExAtlas.Orchestrator.Supervisor`."
    @spec starts_supervisor?(Igniter.t()) :: {Igniter.t(), boolean()}
    def starts_supervisor?(igniter) do
      {igniter, modules} =
        Igniter.Project.Module.find_all_matching_modules(igniter, fn _module, body ->
          names_supervisor?(body)
        end)

      {igniter, modules != []}
    end

    # `Common.nodes_equal?/2` expands aliases, so `alias
    # ExAtlas.Orchestrator.Supervisor` then `Supervisor` matches.
    defp names_supervisor?(body) do
      body
      |> Zipper.traverse(false, fn zipper, found? ->
        {zipper, found? or supervisor_alias?(zipper)}
      end)
      |> elem(1)
    end

    defp supervisor_alias?(%Zipper{node: {:__aliases__, _, _}} = zipper),
      do: Common.nodes_equal?(zipper, @supervisor)

    defp supervisor_alias?(_zipper), do: false

    @doc "Loads `config/<file>` into the igniter when it exists."
    @spec include_config(String.t(), Igniter.t()) :: Igniter.t()
    def include_config(file, igniter) do
      Igniter.include_existing_file(igniter, Path.join("config", file), required?: false)
    end

    defp sets_reap_owner?(igniter, file) do
      config_values(igniter, file, :ex_atlas, [:orchestrator, :reap_owner]) != []
    end

    @doc """
    Whether `config/<file>` sets `start_orchestrator` to `value` anywhere.

    Include the file first with `include_config/2`.
    """
    @spec sets_start_orchestrator?(Igniter.t(), String.t(), boolean()) :: boolean()
    def sets_start_orchestrator?(igniter, file, value) do
      igniter
      |> config_values(file, :ex_atlas, [:start_orchestrator])
      |> Enum.any?(&Common.nodes_equal?(&1, value))
    end

    @doc """
    The value nodes `config/<file>` sets for `app` at `path`.

    Reads every `config` call in the file, inside `if` and `case` blocks too,
    in both forms: `config :app, key: [sub: value]` and
    `config :app, :key, sub: value`. `Igniter.Project.Config` reads only
    top-level calls, and a host's runtime.exs often sets a key under
    `if config_env() == :prod`.
    """
    @spec config_values(Igniter.t(), String.t(), atom(), [atom() | module()]) :: [Zipper.t()]
    def config_values(igniter, file, app, path) do
      case Rewrite.source(igniter.rewrite, Path.join("config", file)) do
        {:ok, source} ->
          source
          |> Rewrite.Source.get(:quoted)
          |> Zipper.zip()
          |> Zipper.traverse([], fn zipper, found ->
            {zipper, found ++ config_call_values(zipper, app, path)}
          end)
          |> elem(1)

        _ ->
          []
      end
    end

    defp config_call_values(zipper, app, [key | rest] = path) do
      cond do
        Function.function_call?(zipper, :config, 2) and Function.argument_equals?(zipper, 0, app) ->
          with {:ok, options} <- Function.move_to_nth_argument(zipper, 1),
               {:ok, value} <- get_path(options, path) do
            [value]
          else
            _ -> []
          end

        Function.function_call?(zipper, :config, 3) and Function.argument_equals?(zipper, 0, app) and
            Function.argument_equals?(zipper, 1, key) ->
          with {:ok, options} <- Function.move_to_nth_argument(zipper, 2),
               {:ok, value} <- get_path(options, rest) do
            [value]
          else
            _ -> []
          end

        true ->
          []
      end
    end

    defp get_path(zipper, []), do: {:ok, zipper}

    defp get_path(zipper, [key | rest]) do
      if IgniterList.list?(zipper) do
        with {:ok, value} <- IgniterKeyword.get_key(zipper, key), do: get_path(value, rest)
      else
        :error
      end
    end
  end
end
