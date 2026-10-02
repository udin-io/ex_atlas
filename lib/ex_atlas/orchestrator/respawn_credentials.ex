defmodule ExAtlas.Orchestrator.RespawnCredentials do
  @moduledoc """
  Marks a module whose functions may serve as a `respawn_credentials:`
  resolver.

  A `persist: true` task's record leaves out its `s3:` credentials and `env:`
  values. When an adopted task respawns, its tracker calls the record's
  `{module, function, args}` as `apply(module, function, args ++ [info])` for
  fresh ones. See "persist: true" in `ExAtlas.Orchestrator.spawn/1`.

      defmodule MyApp.Atlas do
        @behaviour ExAtlas.Orchestrator.RespawnCredentials

        def credentials(:trainer, info) do
          {:ok,
           s3: MyApp.Storage.task_credentials(info.user_id) |> Map.merge(info.s3),
           env: %{"HF_TOKEN" => MyApp.Secrets.hf_token()}}
        end
      end

  The tuple is read back from the tracking store, so whoever can write the
  store picks the function. ExAtlas calls only modules that declare this
  behaviour; `{:os, :cmd, [...]}` in a record is refused. The same check runs
  on the spawn option, on an adopted record and on
  `config :ex_atlas, :orchestrator, respawn_credentials:`.
  """

  @typedoc "What the record keeps about the task, and no value."
  @type info :: %{
          id: String.t(),
          name: String.t() | nil,
          user_id: term(),
          provider: atom() | module(),
          s3: map() | nil,
          env_names: [String.t()] | :unknown
        }

  @typedoc """
  `{:ok, keyword}` with `:s3`, `:env` or both. `s3:` comes back whole, as
  `ExAtlas.Spec.Staging.new/1` takes it. `env:` holds every name in
  `info.env_names`, and may add more.
  """
  @type result ::
          {:ok, [s3: map() | keyword(), env: %{String.t() => String.t()}]} | {:error, term()}

  @doc """
  The shape of a resolver function with no args of its own:
  `{MyApp.Atlas, :respawn_credentials, []}`. A resolver may use any exported
  function name, with any args before `info`.
  """
  @callback respawn_credentials(info()) :: result()

  @optional_callbacks respawn_credentials: 1

  @doc "Whether `module` declares this behaviour."
  @spec declared_by?(module()) :: boolean()
  def declared_by?(module) do
    Code.ensure_loaded?(module) and
      __MODULE__ in List.flatten(Keyword.get_values(module.module_info(:attributes), :behaviour))
  end
end
