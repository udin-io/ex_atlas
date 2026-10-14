defmodule ExAtlas.S3.ConfigTest do
  # Reads and sets the process-wide AWS_* variables.
  use ExUnit.Case, async: false

  alias ExAtlas.S3

  @key_id "AKIA-CONFIG-KEY-ID-7731"
  @secret "config-secret-access-key-9917"
  @vars ~w(AWS_ENDPOINT_URL_S3 AWS_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY)

  setup do
    saved = Map.new(@vars, &{&1, System.get_env(&1)})
    Enum.each(@vars, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)
  end

  defp keys, do: [access_key_id: @key_id, secret_access_key: @secret]

  describe "config!/1 defaults" do
    test "reads the endpoint, region and keys from the AWS_* variables Fly's Tigris sets" do
      System.put_env("AWS_ENDPOINT_URL_S3", "https://fly.storage.tigris.dev")
      System.put_env("AWS_REGION", "auto")
      System.put_env("AWS_ACCESS_KEY_ID", @key_id)
      System.put_env("AWS_SECRET_ACCESS_KEY", @secret)

      s3 = S3.config!(bucket: "media")

      assert s3.endpoint == "https://fly.storage.tigris.dev"
      assert s3.region == "auto"
      assert ExAtlas.Secret.reveal(s3.access_key_id) == @key_id
      assert ExAtlas.Secret.reveal(s3.secret_access_key) == @secret
    end

    test "an option wins over its variable" do
      System.put_env("AWS_ENDPOINT_URL_S3", "https://fly.storage.tigris.dev")
      System.put_env("AWS_REGION", "eu-west-1")
      System.put_env("AWS_ACCESS_KEY_ID", "from-env")

      s3 =
        S3.config!([bucket: "media", endpoint: "http://minio.local:9000", region: "x"] ++ keys())

      assert s3.endpoint == "http://minio.local:9000"
      assert s3.region == "x"
      assert ExAtlas.Secret.reveal(s3.access_key_id) == @key_id
    end

    test "with no endpoint anywhere, AWS's regional endpoint for the region" do
      System.put_env("AWS_REGION", "eu-west-1")

      assert S3.config!([bucket: "media"] ++ keys()).endpoint ==
               "https://s3.eu-west-1.amazonaws.com"
    end

    test "with no endpoint and no region, AWS's us-east-1" do
      s3 = S3.config!([bucket: "media"] ++ keys())
      assert s3.endpoint == "https://s3.us-east-1.amazonaws.com"
      assert s3.region == "us-east-1"
    end

    test "with an endpoint and no region, the region is auto" do
      assert S3.config!([bucket: "media", endpoint: "https://t3.storage.dev"] ++ keys()).region ==
               "auto"
    end

    test "an empty variable counts as unset" do
      System.put_env("AWS_ACCESS_KEY_ID", "")
      System.put_env("AWS_SECRET_ACCESS_KEY", @secret)

      assert_raise NimbleOptions.ValidationError, ~r/:access_key_id.*AWS_ACCESS_KEY_ID/, fn ->
        S3.config!(bucket: "media")
      end
    end

    test "path_style defaults to false: new Tigris buckets answer virtual-hosted URLs only" do
      refute S3.config!([bucket: "media"] ++ keys()).path_style
    end

    test "takes keys already wrapped in ExAtlas.Secret" do
      s3 =
        S3.config!(
          bucket: "media",
          access_key_id: ExAtlas.Secret.wrap(@key_id),
          secret_access_key: ExAtlas.Secret.wrap(@secret)
        )

      assert ExAtlas.Secret.reveal(s3.secret_access_key) == @secret
    end
  end

  describe "config!/1 refusals" do
    test "a missing bucket names the option" do
      assert_raise NimbleOptions.ValidationError, ~r/:bucket/, fn -> S3.config!(keys()) end
    end

    test "a missing key names the option and its variable, and prints no value" do
      error =
        assert_raise NimbleOptions.ValidationError, fn ->
          S3.config!(bucket: "media", access_key_id: @key_id)
        end

      assert Exception.message(error) =~ ":secret_access_key"
      assert Exception.message(error) =~ "AWS_SECRET_ACCESS_KEY"
      refute inspect(error) =~ @key_id

      error = assert_raise NimbleOptions.ValidationError, fn -> S3.config!(bucket: "media") end
      assert Exception.message(error) =~ ":access_key_id"
      assert Exception.message(error) =~ "AWS_ACCESS_KEY_ID"
    end

    test "a key of the wrong type names the option, never the value" do
      error =
        assert_raise NimbleOptions.ValidationError, fn ->
          S3.config!(bucket: "media", access_key_id: @key_id, secret_access_key: {@secret})
        end

      assert Exception.message(error) =~ ":secret_access_key"
      refute inspect(error) =~ @secret
      refute inspect(error) =~ @key_id
    end

    test "an endpoint that is not an http(s) URL with a host" do
      for endpoint <- ["t3.storage.dev", "ftp://t3.storage.dev", "https://", "https://h/prefix"] do
        assert {:error, %NimbleOptions.ValidationError{key: :endpoint}} =
                 S3.config([bucket: "media", endpoint: endpoint] ++ keys())
      end
    end

    test "an endpoint with user info, which would carry a credential" do
      assert {:error, %NimbleOptions.ValidationError{key: :endpoint} = error} =
               S3.config([bucket: "media", endpoint: "https://u:#{@secret}@h.dev"] ++ keys())

      refute inspect(error) =~ @secret
    end

    test "a bucket name S3 does not allow" do
      for bucket <- ["", "ab", "Media", "me/dia", "-media", "media-", String.duplicate("a", 64)] do
        assert {:error, %NimbleOptions.ValidationError{key: :bucket}} =
                 S3.config([bucket: bucket] ++ keys()),
               "accepted #{inspect(bucket)}"
      end

      assert {:ok, _} = S3.config([bucket: "my.media-01"] ++ keys())
    end

    test "an unknown option" do
      assert {:error, %NimbleOptions.ValidationError{key: :buckett}} =
               S3.config([bucket: "media", buckett: "x"] ++ keys())
    end

    test "opts that are not a keyword list" do
      assert {:error, %NimbleOptions.ValidationError{}} = S3.config(%{bucket: "media"})
      assert {:error, %NimbleOptions.ValidationError{}} = S3.config([{:bucket, "m"} | @secret])
    end

    test "req_options that could point the signed request elsewhere" do
      for option <- [:base_url, :url, :aws_sigv4, :redirect, :auth, :headers, :params] do
        assert {:error, %NimbleOptions.ValidationError{key: :req_options} = error} =
                 S3.config([bucket: "media", req_options: [{option, "x"}]] ++ keys())

        assert Exception.message(error) =~ inspect(option)
      end

      assert {:ok, _} =
               S3.config(
                 [bucket: "media", req_options: [retry: false, receive_timeout: 1_000]] ++ keys()
               )
    end

    test "connect_options that change the host, the proxy or certificate checks" do
      for connect <- [
            [proxy: {:http, "evil.example", 80, []}],
            [hostname: "evil.example"],
            [transport_opts: [verify: :verify_none]],
            [transport_opts: [cacertfile: "ca.pem", verify: :verify_none]],
            :not_a_list
          ] do
        assert {:error, %NimbleOptions.ValidationError{key: :req_options}} =
                 S3.config([bucket: "media", req_options: [connect_options: connect]] ++ keys()),
               "accepted #{inspect(connect)}"
      end

      assert {:ok, _} =
               S3.config(
                 [
                   bucket: "media",
                   req_options: [
                     connect_options: [timeout: 5_000, transport_opts: [cacertfile: "ca.pem"]]
                   ]
                 ] ++ keys()
               )
    end
  end

  describe "inspect/1" do
    test "prints the bucket, endpoint and region, and neither key" do
      s3 = S3.config!([bucket: "media", endpoint: "https://t3.storage.dev"] ++ keys())

      printed = inspect(s3)
      assert printed =~ "media"
      assert printed =~ "https://t3.storage.dev"
      refute printed =~ @key_id
      refute printed =~ @secret

      raw = inspect(s3, structs: false)
      refute raw =~ @key_id
      refute raw =~ @secret
    end

    test "ExAtlas.Secret still prints redacted" do
      assert inspect(ExAtlas.Secret.wrap(@secret)) == "#ExAtlas.Secret<redacted>"
    end
  end
end
