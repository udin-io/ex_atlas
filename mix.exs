defmodule Atlas.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/udin-io/atlas"

  def project do
    [
      app: :atlas,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "Atlas",
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Atlas.Application, []}
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
    A composable, pluggable Elixir SDK for managing GPU/compute resources across
    cloud providers (RunPod, Fly.io Machines, Lambda Labs, Vast.ai). Ship pods,
    run serverless inference, and orchestrate transient per-user GPU sessions
    with built-in preshared-key auth and opt-in OTP supervision.
    """
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md),
      maintainers: ["Peter Shoukry"]
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      source_ref: "v#{@version}",
      groups_for_modules: [
        "Core API": [Atlas, Atlas.Config, Atlas.Error],
        "Provider contract": [
          Atlas.Provider,
          Atlas.Spec.ComputeRequest,
          Atlas.Spec.Compute,
          Atlas.Spec.JobRequest,
          Atlas.Spec.Job,
          Atlas.Spec.GpuType,
          Atlas.Spec.GpuCatalog
        ],
        Providers: [
          Atlas.Providers.RunPod,
          Atlas.Providers.Mock,
          Atlas.Providers.Fly,
          Atlas.Providers.LambdaLabs,
          Atlas.Providers.Vast
        ],
        Auth: [Atlas.Auth.Token, Atlas.Auth.SignedUrl],
        "LiveDashboard integration": [Atlas.LiveDashboard.ComputePage],
        Orchestrator: [
          Atlas.Orchestrator,
          Atlas.Orchestrator.ComputeServer,
          Atlas.Orchestrator.ComputeSupervisor,
          Atlas.Orchestrator.ComputeRegistry,
          Atlas.Orchestrator.Reaper,
          Atlas.Orchestrator.Events
        ]
      ]
    ]
  end
end
