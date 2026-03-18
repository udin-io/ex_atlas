defmodule Atlas.Infrastructure.StorageBucketTest do
  use Atlas.DataCase, async: true

  alias Atlas.Infrastructure.StorageBucket
  alias Atlas.Providers.Credential

  setup do
    {:ok, credential} =
      Credential.create(%{
        provider_type: :runpod,
        name: "Test RunPod",
        api_token: "token"
      })

    %{credential: credential}
  end

  describe "create/1" do
    test "creates a storage bucket", %{credential: credential} do
      assert {:ok, bucket} =
               StorageBucket.create(%{
                 provider_id: "vol_abc",
                 name: "shared-data",
                 size_bytes: 107_374_182_400,
                 region: "US-TX-3",
                 credential_id: credential.id
               })

      assert bucket.provider_id == "vol_abc"
      assert bucket.name == "shared-data"
      assert bucket.size_bytes == 107_374_182_400
    end
  end

  describe "upsert/1" do
    test "creates on first call, updates on second", %{credential: credential} do
      params = %{
        provider_id: "vol_xyz",
        name: "my-volume",
        size_bytes: 50_000_000_000,
        credential_id: credential.id
      }

      {:ok, b1} = StorageBucket.upsert(params)
      assert b1.name == "my-volume"

      {:ok, b2} = StorageBucket.upsert(%{params | name: "renamed-volume"})
      assert b2.id == b1.id
      assert b2.name == "renamed-volume"
    end
  end

  describe "by_credential/1" do
    test "returns buckets for a credential", %{credential: credential} do
      {:ok, _} =
        StorageBucket.create(%{
          provider_id: "v1",
          name: "bucket-1",
          credential_id: credential.id
        })

      {:ok, _} =
        StorageBucket.create(%{
          provider_id: "v2",
          name: "bucket-2",
          credential_id: credential.id
        })

      {:ok, buckets} = StorageBucket.by_credential(credential.id)
      assert length(buckets) == 2
    end
  end
end
