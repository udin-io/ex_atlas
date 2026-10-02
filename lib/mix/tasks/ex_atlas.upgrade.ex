if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.ExAtlas.Upgrade do
    @shortdoc "Runs ExAtlas version-specific upgrade steps."

    @moduledoc """
    Runs upgrade steps between ExAtlas versions.

    Invoke after updating the ex_atlas dep:

        mix deps.update ex_atlas
        mix ex_atlas.upgrade

    Or via Igniter's aggregate upgrader:

        mix igniter.upgrade ex_atlas

    ## Arguments

    `mix igniter.upgrade ex_atlas` passes `<from_version> <to_version>`, the
    version in `mix.lock` before the update and the one after. Run directly,
    the task takes `<from_version>` as `0.1.0` and `<to_version>` as the
    installed ex_atlas version, so it runs every upgrader. Each upgrader is
    idempotent. `mix ex_atlas.upgrade 0.7.0 0.8.0` runs the steps in that range
    only.

    ## Registered upgraders

    `0.1` → `0.2` — no-op (placeholder). Reserved for surface migrations
    between the pre-Fly compute-only release and the infrastructure SDK
    release that introduced `ExAtlas.Fly.*`.
    """

    use Igniter.Mix.Task

    # The version of the installed dep, read from its own mix.exs when it
    # compiles. `Application.spec/2` returns nothing while the app is not loaded.
    @atlas_version Mix.Project.config()[:version]

    @impl Igniter.Mix.Task
    def info(_argv, _parent) do
      %Igniter.Mix.Task.Info{
        group: :ex_atlas,
        example: "mix ex_atlas.upgrade",
        positional: [{:from, optional: true}, {:to, optional: true}],
        schema: [],
        aliases: []
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      {from, to} = pick_versions(igniter)
      Igniter.Upgrades.run(igniter, from, to, upgraders(), [])
    end

    defp pick_versions(igniter) do
      args = Map.get(igniter.args, :positional, %{})
      from = Map.get(args, :from) || "0.1.0"
      to = Map.get(args, :to) || @atlas_version
      {from, to}
    end

    defp upgraders do
      %{
        "0.2.0" => &upgrade_0_1_to_0_2/2
      }
    end

    # 0.1 → 0.2 migration.
    #
    # The compute-only 0.1 release had no Fly platform ops and no DETS storage.
    # Re-run the installer to write the new `config :ex_atlas, :fly` defaults and
    # create the storage directory. The installer is idempotent; existing keys
    # are preserved.
    defp upgrade_0_1_to_0_2(igniter, _opts) do
      igniter
      |> Mix.Tasks.ExAtlas.Install.igniter()
      |> Igniter.add_notice("""
      ExAtlas 0.2 introduces the `ExAtlas.Fly.*` namespace (Fly.io platform ops).

      If your app also manages Fly tokens elsewhere, see:
      https://hexdocs.pm/ex_atlas/fly.html#token-lifecycle

      No breaking changes to the compute API.
      """)
    end
  end
else
  defmodule Mix.Tasks.ExAtlas.Upgrade do
    @shortdoc "Runs ExAtlas version-specific upgrade steps (requires Igniter)."
    @moduledoc false
    use Mix.Task

    def run(_argv) do
      Mix.raise("""
      mix ex_atlas.upgrade requires `igniter` to be in your deps.

      Add it to your mix.exs:

          {:igniter, "~> 0.6", only: [:dev]}
      """)
    end
  end
end
