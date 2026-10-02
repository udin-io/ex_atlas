defmodule ExAtlas.Spec.StagingTest do
  use ExUnit.Case, async: true

  alias ExAtlas.Spec.Staging

  # Distinctive strings, so a `refute =~` cannot pass on a common substring.
  @key_id "tid-test-4b1e"
  @secret "tsec-test-9f2c"
  @token "tses-test-0d7a"
  # Presigned URLs are bearer credentials: the signature is the secret part.
  @get_sig "getsig-5d0c91"
  @put_sig "putsig-a7e3b2"
  @get_url "https://bucket.s3.amazonaws.com/datasets/abc.tar.gz?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Signature=#{@get_sig}"
  @put_url "http://minio.local:9000/bucket/artifacts/run-123.tar.gz?X-Amz-Signature=#{@put_sig}"

  @full %{
    endpoint: "https://t3.storage.dev",
    region: "auto",
    access_key_id: @key_id,
    secret_access_key: @secret,
    session_token: @token,
    dataset_uri: "s3://bucket/datasets/abc/",
    artifact_uri: "s3://bucket/artifacts/run-123/",
    dataset_url: @get_url,
    artifact_url: @put_url
  }

  defp refute_secrets(text) do
    for secret <- [@key_id, @secret, @token, @get_sig, @put_sig], do: refute(text =~ secret)
  end

  describe "new/1 and env/1" do
    test "every key becomes its variable" do
      assert {:ok, staging} = Staging.new(@full)

      assert Staging.env(staging) == %{
               "AWS_ENDPOINT_URL_S3" => "https://t3.storage.dev",
               "AWS_REGION" => "auto",
               "AWS_DEFAULT_REGION" => "auto",
               "AWS_ACCESS_KEY_ID" => @key_id,
               "AWS_SECRET_ACCESS_KEY" => @secret,
               "AWS_SESSION_TOKEN" => @token,
               "ATLAS_DATASET_URI" => "s3://bucket/datasets/abc/",
               "ATLAS_ARTIFACT_URI" => "s3://bucket/artifacts/run-123/",
               "ATLAS_DATASET_URL" => @get_url,
               "ATLAS_ARTIFACT_URL" => @put_url
             }
    end

    test "two presigned URLs set two variables and no AWS_* one" do
      assert {:ok, staging} = Staging.new(dataset_url: @get_url, artifact_url: @put_url)

      assert Staging.env(staging) == %{
               "ATLAS_DATASET_URL" => @get_url,
               "ATLAS_ARTIFACT_URL" => @put_url
             }
    end

    test "an IPv6 host and percent-escapes are accepted (control for the character rule)" do
      url = "http://[::1]:9000/bucket/a%20b.tar.gz?X-Amz-Signature=#{@put_sig}&x=1;y=(2)"
      assert {:ok, staging} = Staging.new(artifact_url: url)
      assert Staging.env(staging) == %{"ATLAS_ARTIFACT_URL" => url}
    end

    test "one presigned URL alone is enough, on either side" do
      assert {:ok, staging} = Staging.new(artifact_url: @put_url)
      assert Staging.env(staging) == %{"ATLAS_ARTIFACT_URL" => @put_url}

      assert {:ok, staging} = Staging.new(dataset_url: @get_url)
      assert Staging.env(staging) == %{"ATLAS_DATASET_URL" => @get_url}
    end

    test "a keyword list works like a map" do
      assert {:ok, staging} = Staging.new(Map.to_list(@full))
      assert {:ok, ^staging} = Staging.new(@full)
    end

    test "a key left out sets no variable" do
      assert {:ok, staging} = Staging.new(dataset_uri: "s3://bucket/d/")
      assert Staging.env(staging) == %{"ATLAS_DATASET_URI" => "s3://bucket/d/"}
    end

    test "nil is no staging and no variables" do
      assert {:ok, nil} = Staging.new(nil)
      assert Staging.env(nil) == %{}
    end

    test "a built Staging validates again to itself" do
      {:ok, staging} = Staging.new(@full)
      assert {:ok, ^staging} = Staging.new(staging)
    end

    test "a bucket with dots, dashes and digits is accepted (control)" do
      assert {:ok, _} =
               Staging.new(dataset_uri: "s3://my-bucket.v2/data set/", region: "eu-west-1")
    end

    test "a plain-http endpoint is accepted, for a local MinIO" do
      assert {:ok, _} = Staging.new(endpoint: "http://localhost:9000", artifact_uri: "s3://b")
    end

    test "env/1 refuses a value that Staging.new/1 did not build, without printing it" do
      error = assert_raise ArgumentError, fn -> Staging.env(@full) end
      assert Exception.message(error) =~ "Staging.new/1"
      refute_secrets(Exception.message(error))
    end
  end

  describe "inspect/1" do
    test "shows the URIs and the endpoint and none of the secrets or URLs" do
      {:ok, staging} = Staging.new(@full)
      text = inspect(staging)

      assert text =~ "s3://bucket/datasets/abc/"
      assert text =~ "https://t3.storage.dev"
      refute_secrets(text)
    end

    test "a printer that skips Inspect shows none of the secrets or URLs either" do
      {:ok, staging} = Staging.new(@full)

      for text <- [
            inspect(staging, structs: false),
            :io_lib.format(~c"~p", [staging]) |> IO.iodata_to_binary()
          ] do
        # The URIs printed, so the refute is not vacuous.
        assert text =~ "s3://bucket/datasets/abc/"
        refute_secrets(text)
      end
    end

    test "a Staging passed back to new/1 keeps its credentials" do
      {:ok, staging} = Staging.new(@full)

      assert {:ok, again} = Staging.new(staging)
      assert Staging.env(again)["AWS_SECRET_ACCESS_KEY"] == @secret
      assert Staging.env(again)["ATLAS_DATASET_URL"] == @get_url
      assert Staging.env(again)["ATLAS_ARTIFACT_URL"] == @put_url
    end
  end

  describe "new/1 refusals" do
    # Each row: the input, then text the message must hold to show which
    # clause fired. Every input carries the three secrets where it can, so the
    # refute below has something to find.
    @refusals [
      {"key id without secret", Map.delete(@full, :secret_access_key),
       ":access_key_id and :secret_access_key go together"},
      {"secret without key id", Map.delete(@full, :access_key_id),
       ":access_key_id and :secret_access_key go together"},
      {"session token without keys", %{session_token: @token, dataset_uri: "s3://bucket/d/"},
       ":session_token needs"},
      {"https dataset URI", %{@full | dataset_uri: "https://bucket/d/"},
       ":dataset_uri must start with s3://"},
      {"s3 URI with no bucket", %{@full | dataset_uri: "s3:///d/"},
       ":dataset_uri must start with s3://"},
      {"bad artifact URI", %{@full | artifact_uri: "/local/out"},
       ":artifact_uri must start with s3://"},
      {"unknown key", Map.put(@full, :bucket, "b"), "unknown key :bucket"},
      # What `TrackingStore.scrub_opts/1` writes. Refused even beside a full
      # set of credentials: it can only come from a record.
      {"the not-stored marker", Map.put(@full, :credentials, :not_stored),
       "a tracking record's :s3, which never holds the credentials"},
      {"the not-stored marker as a keyword list",
       [dataset_uri: "s3://bucket/d/", credentials: :not_stored],
       "a tracking record's :s3, which never holds the credentials"},
      {"no URI and no URL",
       Map.drop(@full, [:dataset_uri, :artifact_uri, :dataset_url, :artifact_url]),
       "needs :dataset_uri, :artifact_uri, :dataset_url or :artifact_url"},
      {"an empty map", %{}, "needs :dataset_uri, :artifact_uri, :dataset_url or :artifact_url"},
      {"ftp dataset URL", %{@full | dataset_url: "ftp://x/#{@get_sig}"},
       ":dataset_url must be an http:// or https:// URL"},
      {"dataset URL with no host", %{@full | dataset_url: "https://"},
       ":dataset_url must be an http:// or https:// URL"},
      {"s3 artifact URL", %{@full | artifact_url: "s3://bucket/a?#{@put_sig}"},
       ":artifact_url must be an http:// or https:// URL"},
      {"artifact URL with a bad port",
       %{@full | artifact_url: "http://minio.local:0/a?#{@put_sig}"},
       ":artifact_url must be an http:// or https:// URL"},
      {"user info in a URL",
       %{@full | dataset_url: "https://u:#{@get_sig}@bucket.s3.amazonaws.com/d"},
       ":dataset_url must not carry user info"},
      {"newline in a URL", %{@full | artifact_url: @put_url <> "\nX=1"},
       ":artifact_url must not hold control characters"},
      {"empty URL", %{@full | dataset_url: ""}, ":dataset_url must be a non-empty string"},
      {"curl glob braces in a URL", %{@full | dataset_url: @get_url <> "{"},
       ":dataset_url must hold only URL characters"},
      {"curl glob range in a URL", %{@full | artifact_url: @put_url <> "[1-2]"},
       ":artifact_url must hold only URL characters"},
      {"a space in a URL path", %{@full | dataset_url: "https://b.example/a b?#{@get_sig}"},
       ":dataset_url must hold only URL characters"},
      {"a non-ASCII character in a URL", %{@full | artifact_url: @put_url <> "\u00A0"},
       ":artifact_url must hold only URL characters"},
      {"a zero-width character in a URL", %{@full | dataset_url: @get_url <> "\u200B"},
       ":dataset_url must hold only URL characters"},
      {"a URL with no object path", %{@full | artifact_url: "https://bucket.s3.amazonaws.com"},
       ":artifact_url must name an object"},
      {"a URL whose path is only a slash",
       %{@full | dataset_url: "https://b.example/?#{@get_sig}"},
       ":dataset_url must name an object"},
      {"ftp endpoint", %{@full | endpoint: "ftp://t3.storage.dev"},
       ":endpoint must be an http:// or https:// URL"},
      {"endpoint with no host", %{@full | endpoint: "https://"},
       ":endpoint must be an http:// or https:// URL"},
      {"non-string value", %{@full | region: 1}, ":region must be a non-empty string"},
      {"empty string", %{@full | secret_access_key: ""},
       ":secret_access_key must be a non-empty string"},
      {"string keys", Map.new(@full, fn {k, v} -> {Atom.to_string(k), v} end),
       "keys must be atoms"},
      {"duplicate key", Map.to_list(@full) ++ [secret_access_key: @secret],
       "duplicate key :secret_access_key"},
      {"not a map", @secret, "expected a map or a keyword list"},
      {"improper list", [{:dataset_uri, "s3://bucket/d/"} | @secret],
       "expected a map or a keyword list"},
      {"credentials in the endpoint", %{@full | endpoint: "https://u:#{@secret}@t3.storage.dev"},
       ":endpoint must not carry user info"},
      {"endpoint port out of range", %{@full | endpoint: "http://localhost:99999"},
       ":endpoint must be an http:// or https:// URL"},
      {"control character in a value", %{@full | session_token: @token <> "\nX=1"},
       ":session_token must not hold control characters"},
      {"space in a bucket", %{@full | dataset_uri: "s3://b c/d/"},
       ":dataset_uri must start with s3://"},
      {"blank bucket", %{@full | artifact_uri: "s3:// /a/"},
       ":artifact_uri must start with s3://"},
      {"newline in a URI path", %{@full | dataset_uri: "s3://bucket/d/\nX=1"},
       ":dataset_uri must not hold control characters"},
      {"space in the endpoint", %{@full | endpoint: "https://t3 storage.dev"},
       ":endpoint must be an http:// or https:// URL"},
      {"invalid UTF-8 in a key", %{@full | secret_access_key: @secret <> <<0xFF>>},
       ":secret_access_key must be valid UTF-8"},
      {"invalid UTF-8 in a URI", %{@full | dataset_uri: "s3://bucket/" <> <<0xC3>>},
       ":dataset_uri must be valid UTF-8"}
    ]

    for {name, input, expected} <- @refusals do
      @input input
      @expected expected

      test "#{name} returns a value-free error on :s3" do
        assert {:error, %NimbleOptions.ValidationError{key: :s3, value: nil} = error} =
                 Staging.new(@input)

        assert Exception.message(error) =~ @expected
        refute_secrets(inspect(error))
      end
    end

    test "the full input with the same secrets is accepted (control)" do
      assert {:ok, staging} = Staging.new(@full)
      assert Staging.env(staging)["AWS_SECRET_ACCESS_KEY"] == @secret
      assert Staging.env(staging)["ATLAS_DATASET_URL"] == @get_url
    end
  end
end
