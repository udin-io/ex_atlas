defmodule ExAtlas.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/udin-io/ex_atlas"

  def project do
    [
      app: :ex_atlas,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "ExAtlas",
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {ExAtlas.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:nimble_options, "~> 1.1"},
      {:telemetry, "~> 1.3"},
      {:plug_crypto, "~> 2.1"},
      {:igniter, "~> 0.6", optional: true},
      {:phoenix_pubsub, "~> 2.1", optional: true},
      {:phoenix_live_dashboard, "~> 0.8", optional: true},
      {:phoenix_live_view, "~> 1.0", optional: true},
      {:bypass, "~> 2.1", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
    ]
  end

  defp description do
    """
    Pluggable Elixir SDK for infrastructure management: multi-cloud GPU/CPU
    compute (RunPod, Fly.io Machines, Lambda Labs, Vast.ai) plus Fly.io
    platform ops (deploys, log streaming, token lifecycle). Igniter installer,
    opt-in OTP supervision, preshared-key auth.
    """
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib guides .formatter.exs mix.exs README.md LICENSE CHANGELOG.md),
      # Igniter looks up installers by name convention: `mix ex_atlas.install`
      # is autodiscovered from `Mix.Tasks.ExAtlas.Install`. No extra manifest needed.
      maintainers: ["Peter Shoukry"]
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "guides/getting_started.md",
        "guides/fly.md",
        "guides/transient_pods.md",
        "guides/writing_a_provider.md",
        "guides/telemetry.md",
        "guides/testing.md",
        "LICENSE"
      ],
      groups_for_extras: [
        Guides: ~r{guides/.+\.md}
      ],
      source_ref: "v#{@version}",
      groups_for_modules: [
        "Core API": [ExAtlas, ExAtlas.Config, ExAtlas.Error],
        "Provider contract": [
          ExAtlas.Provider,
          ExAtlas.Spec.ComputeRequest,
          ExAtlas.Spec.Compute,
          ExAtlas.Spec.JobRequest,
          ExAtlas.Spec.Job,
          ExAtlas.Spec.GpuType,
          ExAtlas.Spec.GpuCatalog
        ],
        Providers: [
          ExAtlas.Providers.RunPod,
          ExAtlas.Providers.Mock,
          ExAtlas.Providers.Fly,
          ExAtlas.Providers.LambdaLabs,
          ExAtlas.Providers.Vast
        ],
        "Fly platform ops": [
          ExAtlas.Fly,
          ExAtlas.Fly.Deploy,
          ExAtlas.Fly.Dispatcher,
          ExAtlas.Fly.Tokens,
          ExAtlas.Fly.Tokens.Server,
          ExAtlas.Fly.TokenStorage,
          ExAtlas.Fly.TokenStorage.Dets,
          ExAtlas.Fly.Logs.Client,
          ExAtlas.Fly.Logs.LogEntry,
          ExAtlas.Fly.Logs.Streamer,
          ExAtlas.Fly.Logs.StreamerSupervisor
        ],
        Auth: [ExAtlas.Auth.Token, ExAtlas.Auth.SignedUrl],
        "LiveDashboard integration": [ExAtlas.LiveDashboard.ComputePage],
        Orchestrator: [
          ExAtlas.Orchestrator,
          ExAtlas.Orchestrator.ComputeServer,
          ExAtlas.Orchestrator.ComputeSupervisor,
          ExAtlas.Orchestrator.ComputeRegistry,
          ExAtlas.Orchestrator.Reaper,
          ExAtlas.Orchestrator.Events
        ]
      ]
    ]
  end
end
