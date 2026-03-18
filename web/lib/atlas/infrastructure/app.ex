defmodule Atlas.Infrastructure.App do
  use Ash.Resource,
    otp_app: :atlas,
    domain: Atlas.Infrastructure,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshStateMachine, Ash.Notifier.PubSub]

  postgres do
    table "infrastructure_apps"
    repo Atlas.Repo
  end

  state_machine do
    initial_states [:pending]
    default_initial_state :pending

    transitions do
      transition :deploy, from: [:pending, :suspended, :error], to: :deployed
      transition :suspend, from: [:deployed], to: :suspended
      transition :mark_error, from: [:pending, :deployed, :suspended], to: :error
      transition :mark_destroyed, from: [:deployed, :suspended, :pending, :error], to: :destroyed
    end
  end

  code_interface do
    define :create
    define :upsert
    define :read
    define :by_credential, args: [:credential_id]
    define :get_by_id, action: :by_id, args: [:id]
    define :update
    define :destroy
    define :deploy
    define :suspend
    define :mark_error
    define :mark_destroyed
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [
        :provider_id,
        :name,
        :region,
        :metadata,
        :provider_type,
        :status
      ]

      argument :credential_id, :uuid, allow_nil?: false
      change manage_relationship(:credential_id, :credential, type: :append)
    end

    create :upsert do
      accept [
        :provider_id,
        :name,
        :region,
        :metadata,
        :provider_type,
        :status
      ]

      upsert? true
      upsert_identity :provider_credential
      upsert_fields [:name, :region, :metadata, :status]

      argument :credential_id, :uuid, allow_nil?: false
      change manage_relationship(:credential_id, :credential, type: :append)
      change set_attribute(:synced_at, &DateTime.utc_now/0)
    end

    update :update do
      accept [:name, :region, :metadata, :status]
      change set_attribute(:synced_at, &DateTime.utc_now/0)
    end

    update :deploy do
      accept []
      change transition_state(:deployed)
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
    publish_all :create, ["credential", :credential_id]
    publish_all :update, ["credential", :credential_id]
  end

  attributes do
    uuid_primary_key :id

    attribute :provider_id, :string do
      allow_nil? false
      public? true
    end

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :region, :string do
      public? true
    end

    attribute :metadata, :map do
      default %{}
      public? true
    end

    attribute :provider_type, :atom do
      constraints one_of: [:fly, :runpod]
      allow_nil? false
      public? true
    end

    attribute :status, :atom do
      constraints one_of: [:deployed, :suspended, :pending, :error, :destroyed]
      default :pending
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
    belongs_to :credential, Atlas.Providers.Credential do
      allow_nil? false
    end

    has_many :machines, Atlas.Infrastructure.Machine
    has_many :volumes, Atlas.Infrastructure.Volume
  end

  identities do
    identity :provider_credential, [:provider_id, :credential_id]
  end
end
