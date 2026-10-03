defmodule ExAtlas.MixProject do
  use Mix.Project

  @version "0.10.0"
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
      {:ecto_sqlite3, "~> 0.25", only: [:test]},
      {:ecto_sql, "~> 3.13", optional: true},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.16", only: [:dev, :test], runtime: false},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:nimble_options, "~> 1.1"},
      {:telemetry, "~> 1.3"},
      {:plug_crypto, "~> 2.1"},
      {:plug, "~> 1.16", optional: true},
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
    Pluggable Elixir SDK for infrastructure management: GPU/CPU compute on
    RunPod, Lambda Labs and Vast.ai (Fly.io Machines is a stub), plus
    Fly.io platform ops (deploys, log streaming, token lifecycle). Igniter
    installer, opt-in OTP supervision, preshared-key auth.
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
        "guides/upgrading.md",
        "guides/fly.md",
        "guides/transient_pods.md",
        "guides/data_staging.md",
        "guides/pod_callbacks.md",
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
        "Core API": [ExAtlas, ExAtlas.Application, ExAtlas.Config, ExAtlas.Error],
        "Provider contract": [
          ExAtlas.Provider,
          ExAtlas.Spec.ComputeRequest,
          ExAtlas.Spec.Compute,
          ExAtlas.Spec.JobRequest,
          ExAtlas.Spec.Job,
          ExAtlas.Spec.GpuType,
          ExAtlas.Spec.GpuCatalog,
          ExAtlas.Spec.Endpoint,
          ExAtlas.Spec.NetworkVolume,
          ExAtlas.Spec.NetworkVolumeRequest,
          ExAtlas.Spec.Spend,
          ExAtlas.Spec.Staging,
          ExAtlas.Spec.Template,
          ExAtlas.Spec.TemplateRequest,
          ExAtlas.Secret
        ],
        Providers: [
          ExAtlas.Providers.RunPod,
          ExAtlas.Providers.Mock,
          ExAtlas.Providers.Fly,
          ExAtlas.Providers.LambdaLabs,
          ExAtlas.Providers.Vast
        ],
        "Provider internals": [
          ExAtlas.Providers.HTTP,
          ExAtlas.Providers.Stub,
          ExAtlas.Providers.RunPod.Billing,
          ExAtlas.Providers.RunPod.Catalog,
          ExAtlas.Providers.RunPod.Client,
          ExAtlas.Providers.RunPod.Endpoints,
          ExAtlas.Providers.RunPod.Jobs,
          ExAtlas.Providers.RunPod.NetworkVolumes,
          ExAtlas.Providers.RunPod.Pods,
          ExAtlas.Providers.RunPod.Templates,
          ExAtlas.Providers.RunPod.Translate,
          ExAtlas.Providers.LambdaLabs.Client,
          ExAtlas.Providers.LambdaLabs.Firewall,
          ExAtlas.Providers.LambdaLabs.Translate,
          ExAtlas.Providers.Vast.Client,
          ExAtlas.Providers.Vast.Translate
        ],
        "Fly platform ops": [
          ExAtlas.Fly,
          ExAtlas.Fly.Deploy,
          ExAtlas.Fly.Dispatcher,
          ExAtlas.Fly.Tokens,
          ExAtlas.Fly.Tokens.AppServer,
          ExAtlas.Fly.Tokens.ETSOwner,
          ExAtlas.Fly.Tokens.Registry,
          ExAtlas.Fly.Tokens.Supervisor,
          ExAtlas.Fly.Supervisor,
          ExAtlas.Fly.TokenStorage,
          ExAtlas.Fly.TokenStorage.Dets,
          ExAtlas.Fly.Logs.Client,
          ExAtlas.Fly.Logs.LogEntry,
          ExAtlas.Fly.Logs.Streamer,
          ExAtlas.Fly.Logs.StreamerSupervisor
        ],
        Auth: [ExAtlas.Auth.Token, ExAtlas.Auth.SignedUrl],
        "Pod callbacks": [
          ExAtlas.Callback,
          ExAtlas.Callback.Plug,
          ExAtlas.Callback.Token,
          ExAtlas.Callback.Limiter
        ],
        "LiveDashboard integration": [ExAtlas.LiveDashboard.ComputePage],
        Orchestrator: [
          ExAtlas.Orchestrator,
          ExAtlas.Orchestrator.Supervisor,
          ExAtlas.Orchestrator.ComputeServer,
          ExAtlas.Orchestrator.ComputeSupervisor,
          ExAtlas.Orchestrator.ComputeRegistry,
          ExAtlas.Orchestrator.Reaper,
          ExAtlas.Orchestrator.Adopter,
          ExAtlas.Orchestrator.Lease,
          ExAtlas.Orchestrator.TrackingStore,
          ExAtlas.Orchestrator.TrackingStore.Dets,
          ExAtlas.Orchestrator.TrackingStore.Ecto,
          ExAtlas.Orchestrator.TrackingStore.Ecto.Migration,
          ExAtlas.Orchestrator.Events,
          ExAtlas.Orchestrator.UpstreamStatus,
          ExAtlas.Orchestrator.CostMeter,
          ExAtlas.Orchestrator.Ownership,
          ExAtlas.Orchestrator.RespawnCredentials,
          ExAtlas.Orchestrator.TaskOutcome
        ],
        Testing: [ExAtlas.Test.ProviderConformance, ExAtlas.Orchestrator.TrackingStoreConformance],
        "Mix tasks": [Mix.Tasks.ExAtlas.Install, Mix.Tasks.ExAtlas.Upgrade]
      ]
    ]
  end
end
