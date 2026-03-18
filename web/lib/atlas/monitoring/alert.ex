defmodule Atlas.Monitoring.Alert do
  use Ash.Resource,
    otp_app: :atlas,
    domain: Atlas.Monitoring,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [Ash.Notifier.PubSub]

  postgres do
    table "monitoring_alerts"
    repo Atlas.Repo
  end

  code_interface do
    define :create
    define :read
    define :get_by_id, action: :by_id, args: [:id]
    define :acknowledge
    define :resolve
    define :list_active, action: :active
    define :by_machine, args: [:machine_id]
  end

  actions do
    defaults [:read]

    create :create do
      accept [:severity, :title, :message, :metric_name, :threshold_value, :actual_value]

      argument :machine_id, :uuid
      argument :credential_id, :uuid, allow_nil?: false
      change manage_relationship(:machine_id, :machine, type: :append)
      change manage_relationship(:credential_id, :credential, type: :append)
    end

    update :acknowledge do
      accept []
      change set_attribute(:status, :acknowledged)
      change set_attribute(:acknowledged_at, &DateTime.utc_now/0)
    end

    update :resolve do
      accept []
      change set_attribute(:status, :resolved)
      change set_attribute(:resolved_at, &DateTime.utc_now/0)
    end

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :active do
      filter expr(status in [:firing, :acknowledged])
      prepare build(sort: [inserted_at: :desc])
    end

    read :by_machine do
      argument :machine_id, :uuid, allow_nil?: false
      filter expr(machine_id == ^arg(:machine_id))
      prepare build(sort: [inserted_at: :desc])
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
    publish_all :create, ["alerts"]
    publish_all :update, ["alerts"]
  end

  attributes do
    uuid_primary_key :id

    attribute :severity, :atom do
      constraints one_of: [:info, :warning, :critical]
      allow_nil? false
      public? true
    end

    attribute :status, :atom do
      constraints one_of: [:firing, :acknowledged, :resolved]
      default :firing
      allow_nil? false
      public? true
    end

    attribute :title, :string do
      allow_nil? false
      public? true
    end

    attribute :message, :string do
      public? true
    end

    attribute :metric_name, :string do
      public? true
    end

    attribute :threshold_value, :float do
      public? true
    end

    attribute :actual_value, :float do
      public? true
    end

    attribute :acknowledged_at, :utc_datetime do
      public? true
    end

    attribute :resolved_at, :utc_datetime do
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :machine, Atlas.Infrastructure.Machine

    belongs_to :credential, Atlas.Providers.Credential do
      allow_nil? false
    end
  end
end
