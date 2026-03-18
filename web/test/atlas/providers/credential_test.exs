defmodule Atlas.Providers.CredentialTest do
  use Atlas.DataCase, async: true

  alias Atlas.Providers.Credential

  describe "create/1" do
    test "creates a credential with valid params" do
      assert {:ok, credential} =
               Credential.create(%{
                 provider_type: :fly,
                 name: "Test Fly",
                 api_token: "fo1_test_token",
                 org_slug: "personal"
               })

      assert credential.provider_type == :fly
      assert credential.name == "Test Fly"
      assert credential.org_slug == "personal"
      assert credential.sync_enabled == true
      assert credential.sync_interval_seconds == 60
      assert credential.status == :active
    end

    test "encrypts api_token at rest" do
      {:ok, credential} =
        Credential.create(%{
          provider_type: :fly,
          name: "Test",
          api_token: "secret_token_123"
        })

      # The raw DB value should be encrypted (not the plain token)
      uuid = credential.id

      raw =
        Atlas.Repo.one!(
          from c in "credentials",
            where: c.id == type(^uuid, :binary_id),
            select: c.encrypted_api_token
        )

      refute raw == "secret_token_123"
      assert is_binary(raw)
    end

    test "decrypts api_token on read" do
      {:ok, credential} =
        Credential.create(%{
          provider_type: :fly,
          name: "Test",
          api_token: "my_secret_token"
        })

      {:ok, loaded} = Credential.get_by_id(credential.id)
      assert loaded.api_token == "my_secret_token"
    end

    test "requires provider_type" do
      assert {:error, _} =
               Credential.create(%{
                 name: "Test",
                 api_token: "token"
               })
    end

    test "requires name" do
      assert {:error, _} =
               Credential.create(%{
                 provider_type: :fly,
                 api_token: "token"
               })
    end

    test "requires api_token" do
      assert {:error, _} =
               Credential.create(%{
                 provider_type: :fly,
                 name: "Test"
               })
    end
  end

  describe "list_sync_enabled/0" do
    test "returns only sync-enabled, non-disabled credentials" do
      {:ok, _} =
        Credential.create(%{
          provider_type: :fly,
          name: "Enabled",
          api_token: "token1",
          sync_enabled: true
        })

      {:ok, disabled} =
        Credential.create(%{
          provider_type: :fly,
          name: "Disabled",
          api_token: "token2",
          sync_enabled: false
        })

      {:ok, results} = Credential.list_sync_enabled()
      ids = Enum.map(results, & &1.id)

      refute disabled.id in ids
      assert length(results) >= 1
    end
  end

  describe "mark_synced/1" do
    test "updates last_synced_at and status" do
      {:ok, credential} =
        Credential.create(%{
          provider_type: :fly,
          name: "Test",
          api_token: "token"
        })

      {:ok, updated} = Credential.mark_synced(credential)

      assert updated.last_synced_at != nil
      assert updated.status == :active
    end
  end

  describe "mark_error/2" do
    test "sets error status and message" do
      {:ok, credential} =
        Credential.create(%{
          provider_type: :fly,
          name: "Test",
          api_token: "token"
        })

      {:ok, updated} = Credential.mark_error(credential, %{message: "Connection failed"})

      assert updated.status == :error
      assert updated.status_message == "Connection failed"
    end
  end
end
