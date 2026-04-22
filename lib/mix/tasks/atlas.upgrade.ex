if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Atlas.Upgrade do
    @shortdoc "Runs Atlas version-specific upgrade steps."

    @moduledoc """
    Runs upgrade steps between Atlas versions.

    Invoke after updating the atlas dep:

        mix deps.update atlas
        mix atlas.upgrade

    Or via Igniter's aggregate upgrader:

        mix igniter.upgrade atlas

    ## Arguments

    When called directly by `mix igniter.upgrade`, receives `<from_version> <to_version>`.
    When called directly by you, reads versions from `mix.lock` and the current
    atlas mix.exs; defaults to running *all* upgraders if versions can't be
    determined.

    ## Registered upgraders

    `0.1` → `0.2` — no-op (placeholder). Reserved for surface migrations
    between the pre-Fly compute-only release and the infrastructure SDK
    release that introduced `Atlas.Fly.*`.
    """

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _parent) do
      %Igniter.Mix.Task.Info{
        group: :atlas,
        example: "mix atlas.upgrade",
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
      to = Map.get(args, :to) || atlas_version()
      {from, to}
    end

    defp atlas_version do
      case :application.get_key(:atlas, :vsn) do
        {:ok, vsn} -> to_string(vsn)
        _ -> "0.2.0"
      end
    end

    defp upgraders do
      %{
        "0.2.0" => &upgrade_0_1_to_0_2/2
      }
    end

    # 0.1 → 0.2 migration.
    #
    # The compute-only 0.1 release had no Fly platform ops and no DETS storage.
    # Re-run the installer to write the new `config :atlas, :fly` defaults and
    # create the storage directory. The installer is idempotent; existing keys
    # are preserved.
    defp upgrade_0_1_to_0_2(igniter, _opts) do
      igniter
      |> Mix.Tasks.Atlas.Install.igniter()
      |> Igniter.add_notice("""
      Atlas 0.2 introduces the `Atlas.Fly.*` namespace (Fly.io platform ops).

      If your app also manages Fly tokens elsewhere, see:
      https://hexdocs.pm/atlas/fly.html#token-lifecycle

      No breaking changes to the compute API.
      """)
    end
  end
else
  defmodule Mix.Tasks.Atlas.Upgrade do
    @shortdoc "Runs Atlas version-specific upgrade steps (requires Igniter)."
    @moduledoc false
    use Mix.Task

    def run(_argv) do
      Mix.raise("""
      mix atlas.upgrade requires `igniter` to be in your deps.

      Add it to your mix.exs:

          {:igniter, "~> 0.6", only: [:dev]}
      """)
    end
  end
end
