defmodule ExAtlas.S3LiveTest do
  # Runs against a real S3-compatible store, which signs and parses for real.
  # Excluded by default. Checked against SeaweedFS's S3 gateway; with a
  # throwaway local MinIO:
  #
  #     docker run -d --rm -p 9000:9000 -e MINIO_ROOT_USER=minio-key-4471 \
  #       -e MINIO_ROOT_PASSWORD=atlas-secret minio/minio server /data
  #     S3_LIVE_ENDPOINT=http://127.0.0.1:9000 S3_LIVE_BUCKET=atlas-live \
  #       S3_LIVE_PATH_STYLE=true AWS_ACCESS_KEY_ID=minio-key-4471 \
  #       AWS_SECRET_ACCESS_KEY=atlas-secret mix test --only s3_live
  #
  # The bucket must exist; the test writes and deletes under one random folder.
  use ExUnit.Case, async: false

  alias ExAtlas.Error
  alias ExAtlas.S3

  @moduletag :s3_live

  setup do
    s3 =
      S3.config!(
        bucket: System.fetch_env!("S3_LIVE_BUCKET"),
        endpoint: System.fetch_env!("S3_LIVE_ENDPOINT"),
        path_style: System.get_env("S3_LIVE_PATH_STYLE") == "true"
      )

    folder = "atlas-live-#{System.unique_integer([:positive])}"
    on_exit(fn -> S3.delete_prefix(s3, folder) end)
    %{s3: s3, folder: folder}
  end

  test "put, get, head, list and delete round-trip keys with special characters",
       %{s3: s3, folder: folder} do
    names = ["a b.jpg", "a+b", "100%", "q?x=1", "h#1", "café ü.jpg", "x&y<z>.txt"]

    for name <- names do
      assert :ok = S3.put(s3, "#{folder}/#{name}", name, content_type: "text/plain")
      assert {:ok, ^name} = S3.get(s3, "#{folder}/#{name}")
    end

    assert :ok = S3.put(s3, "#{folder}/sub/deep.txt", "deep")

    assert {:ok, %{size: 7, content_type: "text/plain", etag: etag}} =
             S3.head(s3, "#{folder}/a b.jpg")

    assert etag =~ ~r/\A[0-9a-f]{32}\z/

    assert {:ok, listed} = S3.list(s3, folder)
    assert listed == Enum.sort(["sub" | names])

    assert {:error, %Error{kind: :not_found}} = S3.get(s3, "#{folder}/missing")
    assert {:error, %Error{kind: :not_found}} = S3.head(s3, "#{folder}/missing")
    assert :ok = S3.delete(s3, "#{folder}/missing")
    assert :ok = S3.delete(s3, "#{folder}/a+b")
    assert {:error, %Error{kind: :not_found}} = S3.get(s3, "#{folder}/a+b")

    assert {:ok, 7} = S3.delete_prefix(s3, folder)
    # A filer-backed store (SeaweedFS) can still list the empty `sub/` folder,
    # so the check is that no object is left at any depth.
    assert {:ok, 0} = S3.delete_prefix(s3, folder)
  end

  test "lists past 1,000 keys and deletes them in two batches", %{s3: s3, folder: folder} do
    1..1001
    |> Task.async_stream(&S3.put(s3, "#{folder}/f#{&1}", "x"), max_concurrency: 32)
    |> Enum.each(fn result -> assert result == {:ok, :ok} end)

    assert {:ok, names} = S3.list(s3, folder)
    assert length(names) == 1001
    assert {:ok, 1001} = S3.delete_prefix(s3, folder)
    assert {:ok, 0} = S3.delete_prefix(s3, folder)
  end

  test "presigned PUT and GET URLs work with no key, for keys with special characters",
       %{s3: s3, folder: folder} do
    names = [
      "a b.jpg",
      "a+b",
      "100%",
      "q?x=1",
      "h#1",
      "café ü.jpg",
      "x&y<z>.txt",
      "~!$'()*,;=@[]"
    ]

    for name <- names do
      key = "#{folder}/#{name}"
      assert {:ok, put_url} = S3.presign(s3, :put, key, expires_in: 60)
      assert {:ok, %{status: 200}} = Req.put(put_url, body: name, retry: false)

      assert {:ok, get_url} = S3.presign(s3, :get, key, expires_in: 60)

      assert {:ok, %{status: 200, body: ^name}} =
               Req.get(get_url, retry: false, decode_body: false)

      assert {:ok, ^name} = S3.get(s3, key)
    end

    expired = DateTime.add(DateTime.utc_now(), -120)

    assert {:ok, old_url} =
             S3.presign(s3, :get, "#{folder}/a b.jpg", expires_in: 60, now: expired)

    assert {:ok, %{status: 403}} = Req.get(old_url, retry: false)

    assert {:ok, ok_url} = S3.presign(s3, :get, "#{folder}/a b.jpg", expires_in: 60)
    tampered = String.replace(ok_url, "X-Amz-Expires=60", "X-Amz-Expires=600")
    assert {:ok, %{status: 403}} = Req.get(tampered, retry: false)

    assert {:ok, acl_url} = S3.presign(s3, :put, "#{folder}/acl.txt", expires_in: 60)

    assert {:ok, %{status: 403}} =
             Req.put(acl_url, body: "x", headers: [{"x-amz-acl", "public-read"}], retry: false)
  end

  test "a wrong secret is :forbidden and the error holds no key", %{s3: s3, folder: folder} do
    bad = %{s3 | secret_access_key: ExAtlas.Secret.wrap("wrong-secret-0000")}
    key_id = ExAtlas.Secret.reveal(s3.access_key_id)

    assert {:error, %Error{kind: :forbidden} = error} = S3.get(bad, "#{folder}/x")
    refute inspect(error, structs: false) =~ key_id
  end
end
