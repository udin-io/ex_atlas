if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Atlas.Install do
    @shortdoc "Installs Atlas — writes sensible config defaults and creates storage dirs."

    @moduledoc """
    Installs Atlas into your project.

    Run this once after adding `{:atlas, "~> 0.2"}` to `mix.exs`:

        mix atlas.install

    Or use Igniter's installer entry point, which handles the dep addition too:

        mix igniter.install atlas

    ## What it does

      * Writes `config :atlas, :fly, ...` defaults to `config/config.exs`:
        dispatcher mode (chosen based on whether `phoenix_pubsub` is present),
        DETS storage path under `priv/atlas_fly`, and the Fly sub-tree
        `enabled: true`.
      * Creates `priv/atlas_fly/` so DETS has somewhere to write on first run.
      * Adds `.gitignore` rules for the DETS files (`priv/atlas_fly/*.dets`).

    Idempotent — re-running is safe; `mix atlas.upgrade` handles version-over-version
    migrations.
    """

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _parent) do
      %Igniter.Mix.Task.Info{
        group: :atlas,
        example: "mix atlas.install",
        schema: [],
        aliases: []
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      igniter
      |> configure_fly_defaults()
      |> create_storage_dir()
      |> update_gitignore()
      |> Igniter.add_notice("""
      Atlas installed.

      • Run `mix atlas.upgrade` after updating the dep in the future.
      • Fly ops: see `Atlas.Fly` or the guide at https://hexdocs.pm/atlas/fly.html.
      • Disable the Fly sub-tree with `config :atlas, :fly, enabled: false`.
      """)
    end

    # Writes default `config :atlas, :fly` block. Each key is only written if
    # it's not already set, so re-running is safe.
    defp configure_fly_defaults(igniter) do
      has_pubsub? = Igniter.Project.Deps.has_dep?(igniter, :phoenix_pubsub)

      igniter =
        igniter
        |> Igniter.Project.Config.configure(
          "config.exs",
          :atlas,
          [:fly, :enabled],
          true,
          updater: &already_set/1
        )
        |> Igniter.Project.Config.configure(
          "config.exs",
          :atlas,
          [:fly, :storage_path],
          "priv/atlas_fly",
          updater: &already_set/1
        )

      if has_pubsub? do
        Igniter.Project.Config.configure(
          igniter,
          "config.exs",
          :atlas,
          [:fly, :dispatcher],
          :phoenix_pubsub,
          updater: &already_set/1
        )
      else
        Igniter.Project.Config.configure(
          igniter,
          "config.exs",
          :atlas,
          [:fly, :dispatcher],
          :registry,
          updater: &already_set/1
        )
      end
    end

    # `updater` that preserves whatever the user already has.
    defp already_set(zipper), do: {:ok, zipper}

    defp create_storage_dir(igniter) do
      Igniter.mkdir(igniter, "priv/atlas_fly")
    end

    defp update_gitignore(igniter) do
      Igniter.update_file(igniter, ".gitignore", fn source ->
        Rewrite.Source.update(source, :content, fn content ->
          content = content || ""

          if String.contains?(content, "priv/atlas_fly") do
            content
          else
            trailing = if String.ends_with?(content, "\n") or content == "", do: "", else: "\n"

            content <>
              trailing <>
              "\n# Atlas DETS token cache\npriv/atlas_fly/*.dets\n"
          end
        end)
      end)
    rescue
      _ -> igniter
    end
  end
else
  defmodule Mix.Tasks.Atlas.Install do
    @shortdoc "Installs Atlas (requires Igniter)."
    @moduledoc false
    use Mix.Task

    def run(_argv) do
      Mix.raise("""
      mix atlas.install requires `igniter` to be in your deps.

      Add it to your mix.exs:

          {:igniter, "~> 0.6", only: [:dev]}

      Then run `mix deps.get` and retry.

      Alternatively, configure Atlas manually:

          # config/config.exs
          config :atlas, :fly,
            enabled: true,
            dispatcher: :registry,
            storage_path: "priv/atlas_fly"
      """)
    end
  end
end
