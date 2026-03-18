defmodule Atlas.Infrastructure.Machine do
  use Ash.Resource,
    otp_app: :atlas,
    domain: Atlas.Infrastructure,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine, Ash.Notifier.PubSub]

  postgres do
    table "infrastructure_machines"
    repo Atlas.Repo
  end

  state_machine do
    initial_states [:created]
    default_initial_state :created

    transitions do
      transition :start, from: [:created, :stopped, :suspended], to: :started
      transition :stop, from: [:started], to: :stopped
      transition :suspend, from: [:started], to: :suspended
      transition :mark_error, from: [:created, :started, :stopped, :suspended], to: :error

      transition :mark_destroyed,
        from: [:created, :started, :stopped, :suspended, :error],
        to: :destroyed
    end
  end

  code_interface do
    define :create
    define :upsert
    define :read
    define :by_app, args: [:app_id]
    define :by_credential, args: [:credential_id]
    define :get_by_id, action: :by_id, args: [:id]
    define :update
    define :destroy
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [
        :provider_id,
        :name,
        :region,
        :image,
        :ip_addresses,
        :cpu_kind,
        :cpus,
        :memory_mb,
        :gpu_type,
        :status
      ]

      argument :app_id, :uuid, allow_nil?: false
      argument :credential_id, :uuid, allow_nil?: false
      change manage_relationship(:app_id, :app, type: :append)
      change manage_relationship(:credential_id, :credential, type: :append)
    end

    create :upsert do
      accept [
        :provider_id,
        :name,
        :region,
        :image,
        :ip_addresses,
        :cpu_kind,
        :cpus,
        :memory_mb,
        :gpu_type,
        :status
      ]

      upsert? true
      upsert_identity :provider_credential

      upsert_fields [
        :name,
        :region,
        :image,
        :ip_addresses,
        :cpu_kind,
        :cpus,
        :memory_mb,
        :gpu_type,
        :status
      ]

      argument :app_id, :uuid, allow_nil?: false
      argument :credential_id, :uuid, allow_nil?: false
      change manage_relationship(:app_id, :app, type: :append)
      change manage_relationship(:credential_id, :credential, type: :append)
      change set_attribute(:synced_at, &DateTime.utc_now/0)
    end

    update :update do
      accept [
        :name,
        :region,
        :image,
        :ip_addresses,
        :cpu_kind,
        :cpus,
        :memory_mb,
        :gpu_type,
        :status
      ]

      change set_attribute(:synced_at, &DateTime.utc_now/0)
    end

    update :start do
      accept []
      change transition_state(:started)
    end

    update :stop do
      accept []
      change transition_state(:stopped)
    end

    update :suspend do
      accept []
      change transition_state(:suspended)
    end

    update :mark_error do
      accept []
      change transition_state(:error)
    end

    update :mark_destroyed do
      accept []
      change transition_state(:destroyed)
    end

    read :by_app do
      argument :app_id, :uuid, allow_nil?: false
      filter expr(app_id == ^arg(:app_id))
    end

    read :by_credential do
      argument :credential_id, :uuid, allow_nil?: false
      filter expr(credential_id == ^arg(:credential_id))
    end

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end
  end

  policies do
    policy always() do
      authorize_if always()
    end
  end

  pub_sub do
    module Atlas.PubSub
    prefix "infrastructure"
    publish_all :create, ["app", :app_id]
    publish_all :update, ["app", :app_id]
  end

  attributes do
    uuid_primary_key :id

    attribute :provider_id, :string do
      allow_nil? false
      public? true
    end

    attribute :name, :string do
      public? true
    end

    attribute :region, :string do
      public? true
    end

    attribute :image, :string do
      public? true
    end

    attribute :ip_addresses, {:array, :string} do
      default []
      public? true
    end

    attribute :cpu_kind, :string do
      public? true
    end

    attribute :cpus, :integer do
      public? true
    end

    attribute :memory_mb, :integer do
      public? true
    end

    attribute :gpu_type, :string do
      public? true
    end

    attribute :status, :atom do
      constraints one_of: [:created, :started, :stopped, :suspended, :destroyed, :error]
      default :created
      allow_nil? false
      public? true
    end

    attribute :synced_at, :utc_datetime do
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :app, Atlas.Infrastructure.App do
      allow_nil? false
    end

    belongs_to :credential, Atlas.Providers.Credential do
      allow_nil? false
    end
  end

  identities do
    identity :provider_credential, [:provider_id, :credential_id]
  end
end
