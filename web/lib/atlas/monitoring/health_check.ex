defmodule Atlas.Monitoring.HealthCheck do
  use Ash.Resource,
    otp_app: :atlas,
    domain: Atlas.Monitoring,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [Ash.Notifier.PubSub]

  postgres do
    table "monitoring_health_checks"
    repo Atlas.Repo
  end

  code_interface do
    define :create
    define :read
    define :by_machine, args: [:machine_id]
    define :recent, args: [:machine_id]
  end

  actions do
    defaults [:read]

    create :create do
      accept [:status, :response_time_ms, :details]

      argument :machine_id, :uuid, allow_nil?: false
      argument :credential_id, :uuid, allow_nil?: false
      change manage_relationship(:machine_id, :machine, type: :append)
      change manage_relationship(:credential_id, :credential, type: :append)
    end

    read :by_machine do
      argument :machine_id, :uuid, allow_nil?: false
      filter expr(machine_id == ^arg(:machine_id))

      prepare build(sort: [inserted_at: :desc])
    end

    read :recent do
      argument :machine_id, :uuid, allow_nil?: false
      filter expr(machine_id == ^arg(:machine_id))

      prepare build(sort: [inserted_at: :desc], limit: 20)
    end
  end

  policies do
    policy always() do
      authorize_if always()
    end
  end

  pub_sub do
    module Atlas.PubSub
    prefix "monitoring"
    publish_all :create, ["health_check", :machine_id]
  end

  attributes do
    uuid_primary_key :id

    attribute :status, :atom do
      constraints one_of: [:healthy, :degraded, :unhealthy, :unreachable]
      allow_nil? false
      public? true
    end

    attribute :response_time_ms, :integer do
      public? true
    end

    attribute :details, :map do
      default %{}
      public? true
    end

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :machine, Atlas.Infrastructure.Machine do
      allow_nil? false
    end

    belongs_to :credential, Atlas.Providers.Credential do
      allow_nil? false
    end
  end
end
