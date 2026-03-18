defmodule Atlas.Providers.Credential do
  use Ash.Resource,
    otp_app: :atlas,
    domain: Atlas.Providers,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshCloak, Ash.Notifier.PubSub]

  postgres do
    table "credentials"
    repo Atlas.Repo
  end

  cloak do
    vault(Atlas.Vault)
    attributes [:api_token]
    decrypt_by_default([:api_token])
  end

  code_interface do
    define :create
    define :read
    define :get_by_id, action: :by_id, args: [:id]
    define :update
    define :destroy
    define :list_active, action: :active
    define :list_sync_enabled, action: :sync_enabled
    define :test_connection, args: [:id]
    define :mark_synced
    define :mark_error
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:provider_type, :name, :api_token, :org_slug, :sync_enabled, :sync_interval_seconds]
    end

    update :update do
      accept [
        :name,
        :api_token,
        :org_slug,
        :sync_enabled,
        :sync_interval_seconds,
        :status,
        :status_message
      ]
    end

    update :mark_synced do
      accept []
      change set_attribute(:last_synced_at, &DateTime.utc_now/0)
      change set_attribute(:status, :active)
      change set_attribute(:status_message, nil)
    end

    update :mark_error do
      accept []
      argument :message, :string, allow_nil?: false
      change set_attribute(:status, :error)
      change set_attribute(:status_message, arg(:message))
    end

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :active do
      filter expr(status == :active)
    end

    read :sync_enabled do
      filter expr(sync_enabled == true and status != :disabled)
    end

    action :test_connection, :map do
      argument :id, :uuid, allow_nil?: false

      run fn input, _context ->
        with {:ok, credential} <- Atlas.Providers.Credential.get_by_id(input.arguments.id),
             {:ok, adapter} <- Atlas.Providers.Adapter.adapter_for(credential.provider_type),
             :ok <- adapter.test_connection(credential) do
          {:ok, %{status: :ok, message: "Connection successful"}}
        else
          {:error, reason} ->
            {:ok, %{status: :error, message: to_string(reason)}}
        end
      end
    end
  end

  policies do
    policy always() do
      authorize_if always()
    end
  end

  pub_sub do
    module Atlas.PubSub
    prefix "providers"
    publish_all :create, ["credentials"]
    publish_all :update, ["credentials"]
    publish_all :destroy, ["credentials"]
  end

  attributes do
    uuid_primary_key :id

    attribute :provider_type, :atom do
      constraints one_of: [:fly, :runpod]
      allow_nil? false
      public? true
    end

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :api_token, :string do
      allow_nil? false
      sensitive? true
      public? true
    end

    attribute :org_slug, :string do
      public? true
    end

    attribute :sync_enabled, :boolean do
      default true
      allow_nil? false
      public? true
    end

    attribute :sync_interval_seconds, :integer do
      default 60
      allow_nil? false
      public? true
    end

    attribute :last_synced_at, :utc_datetime do
      public? true
    end

    attribute :status, :atom do
      constraints one_of: [:active, :error, :disabled]
      default :active
      allow_nil? false
      public? true
    end

    attribute :status_message, :string do
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :apps, Atlas.Infrastructure.App
    has_many :machines, Atlas.Infrastructure.Machine
    has_many :volumes, Atlas.Infrastructure.Volume
    has_many :storage_buckets, Atlas.Infrastructure.StorageBucket
    has_many :alerts, Atlas.Monitoring.Alert
    has_many :health_checks, Atlas.Monitoring.HealthCheck
  end
end
