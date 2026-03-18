defmodule Atlas.Infrastructure.Volume do
  use Ash.Resource,
    otp_app: :atlas,
    domain: Atlas.Infrastructure,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [Ash.Notifier.PubSub]

  postgres do
    table "infrastructure_volumes"
    repo Atlas.Repo
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
      accept [:provider_id, :name, :size_gb, :region, :status]

      argument :app_id, :uuid, allow_nil?: false
      argument :credential_id, :uuid, allow_nil?: false
      change manage_relationship(:app_id, :app, type: :append)
      change manage_relationship(:credential_id, :credential, type: :append)
    end

    create :upsert do
      accept [:provider_id, :name, :size_gb, :region, :status]

      upsert? true
      upsert_identity :provider_credential
      upsert_fields [:name, :size_gb, :region, :status]

      argument :app_id, :uuid, allow_nil?: false
      argument :credential_id, :uuid, allow_nil?: false
      change manage_relationship(:app_id, :app, type: :append)
      change manage_relationship(:credential_id, :credential, type: :append)
      change set_attribute(:synced_at, &DateTime.utc_now/0)
    end

    update :update do
      accept [:name, :size_gb, :region, :status]
      change set_attribute(:synced_at, &DateTime.utc_now/0)
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

    attribute :size_gb, :integer do
      public? true
    end

    attribute :region, :string do
      public? true
    end

    attribute :status, :string do
      default "created"
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
