if Code.ensure_loaded?(Igniter) do
  defmodule Mix.ExAtlas.OrchestratorConfig do
    @moduledoc false
    # Reads a host project's orchestrator setup for `mix ex_atlas.install` and
    # `mix ex_atlas.upgrade`.

    alias Igniter.Code.Common
    alias Igniter.Code.Function
    alias Igniter.Code.Keyword, as: IgniterKeyword
    alias Igniter.Project.Config
    alias Sourceror.Zipper

    @guide_url "https://hexdocs.pm/ex_atlas/upgrading.html"
    @config_files ["config.exs", "runtime.exs", "prod.exs"]
    @supervisor {:__aliases__, [], [:ExAtlas, :Orchestrator, :Supervisor]}

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
      Config.configures_key?(igniter, file, :ex_atlas, [:orchestrator, :reap_owner])
    end

    @doc """
    Whether `config/<file>` holds `config :ex_atlas, start_orchestrator: <value>`.

    Include the file first with `include_config/2`.
    """
    @spec sets_start_orchestrator?(Igniter.t(), String.t(), boolean()) :: boolean()
    def sets_start_orchestrator?(igniter, file, value) do
      case Rewrite.source(igniter.rewrite, Path.join("config", file)) do
        {:ok, source} ->
          zipper = source |> Rewrite.Source.get(:quoted) |> Zipper.zip()

          case Function.move_to_function_call_in_current_scope(
                 zipper,
                 :config,
                 2,
                 &start_orchestrator?(&1, value)
               ) do
            {:ok, _call} -> true
            :error -> false
          end

        _ ->
          false
      end
    end

    defp start_orchestrator?(call, value) do
      Function.argument_equals?(call, 0, :ex_atlas) and
        Function.argument_matches_predicate?(call, 1, fn options ->
          case IgniterKeyword.get_key(options, :start_orchestrator) do
            {:ok, found} -> Common.nodes_equal?(Zipper.node(found), value)
            :error -> false
          end
        end)
    end
  end
end
