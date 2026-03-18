defmodule Atlas.Infrastructure.AppTest do
  use Atlas.DataCase, async: true

  alias Atlas.Infrastructure.App
  alias Atlas.Providers.Credential

  setup do
    {:ok, credential} =
      Credential.create(%{
        provider_type: :fly,
        name: "Test",
        api_token: "token"
      })

    %{credential: credential}
  end

  describe "create/1" do
    test "creates an app", %{credential: credential} do
      assert {:ok, app} =
               App.create(%{
                 provider_id: "app123",
                 name: "my-app",
                 provider_type: :fly,
                 credential_id: credential.id
               })

      assert app.provider_id == "app123"
      assert app.name == "my-app"
      assert app.status == :pending
    end
  end

  describe "upsert/1" do
    test "creates on first call, updates on second", %{credential: credential} do
      params = %{
        provider_id: "app123",
        name: "my-app",
        provider_type: :fly,
        status: :deployed,
        credential_id: credential.id
      }

      {:ok, app1} = App.upsert(params)
      assert app1.name == "my-app"
      assert app1.status == :deployed

      {:ok, app2} = App.upsert(%{params | name: "updated-app"})
      assert app2.id == app1.id
      assert app2.name == "updated-app"
    end

    test "sets synced_at on upsert", %{credential: credential} do
      {:ok, app} =
        App.upsert(%{
          provider_id: "app456",
          name: "sync-test",
          provider_type: :fly,
          credential_id: credential.id
        })

      assert app.synced_at != nil
    end
  end

  describe "by_credential/1" do
    test "returns apps for a credential", %{credential: credential} do
      {:ok, _} =
        App.create(%{
          provider_id: "a1",
          name: "app-1",
          provider_type: :fly,
          credential_id: credential.id
        })

      {:ok, _} =
        App.create(%{
          provider_id: "a2",
          name: "app-2",
          provider_type: :fly,
          credential_id: credential.id
        })

      {:ok, apps} = App.by_credential(credential.id)
      assert length(apps) == 2
    end
  end
end
