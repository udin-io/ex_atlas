defmodule Atlas.Monitoring.MetricSnapshot do
  use Ash.Resource,
    otp_app: :atlas,
    domain: Atlas.Monitoring,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "monitoring_metric_snapshots"
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
      accept [:metric_name, :value, :unit, :tags]

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

      prepare build(sort: [inserted_at: :desc], limit: 50)
    end
  end

  policies do
    policy always() do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :metric_name, :string do
      allow_nil? false
      public? true
    end

    attribute :value, :float do
      allow_nil? false
      public? true
    end

    attribute :unit, :string do
      public? true
    end

    attribute :tags, :map do
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
