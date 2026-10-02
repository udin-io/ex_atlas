defmodule ExAtlas.Spec.ComputeRequestTest do
  use ExUnit.Case, async: true

  alias ExAtlas.Spec.{ComputeRequest, Staging}

  @key_id "tid-test-4b1e"
  @secret "tsec-test-9f2c"
  @token "tses-test-0d7a"

  @s3 %{
    endpoint: "https://t3.storage.dev",
    region: "auto",
    access_key_id: @key_id,
    secret_access_key: @secret,
    session_token: @token,
    dataset_uri: "s3://bucket/datasets/abc/",
    artifact_uri: "s3://bucket/artifacts/run-123/"
  }

  defp refute_secrets(text) do
    for secret <- [@key_id, @secret, @token], do: refute(text =~ secret)
  end

  test "new!/1 builds with defaults" do
    req = ComputeRequest.new!(gpu: :h100)
    assert req.gpu == :h100
    assert req.gpu_count == 1
    assert req.cloud_type == :any
    assert req.spot == false
    assert req.auth == :none
  end

  test "new!/1 raises without :gpu" do
    assert_raise NimbleOptions.ValidationError, fn ->
      ComputeRequest.new!(image: "x")
    end
  end

  test "new/1 returns error tuple for invalid cloud_type" do
    assert {:error, %NimbleOptions.ValidationError{}} =
             ComputeRequest.new(gpu: :h100, cloud_type: :hybrid)
  end

  test "new!/1 accepts a map" do
    req = ComputeRequest.new!(%{gpu: :h100, spot: true})
    assert req.spot == true
  end

  test "new!/1 defaults to no command and to self-termination" do
    req = ComputeRequest.new!(gpu: :h100)
    assert req.command == nil
    assert req.self_terminate == true
  end

  test "new!/1 takes a command as a list of strings" do
    req = ComputeRequest.new!(gpu: :h100, command: ["/app/train.sh", "--epochs", "3"])
    assert req.command == ["/app/train.sh", "--epochs", "3"]
  end

  test "new/1 rejects a command that is not a list of strings" do
    assert {:error, %NimbleOptions.ValidationError{}} =
             ComputeRequest.new(gpu: :h100, command: "/app/train.sh")
  end

  describe "env validation errors" do
    test "a non-string value returns an error that holds no env value" do
      assert {:error, %NimbleOptions.ValidationError{key: :env, value: nil} = error} =
               ComputeRequest.new(gpu: :h100, env: %{"K" => "v-secret-71a4", "N" => 1})

      assert Exception.message(error) =~ ~s(:env)
      assert Exception.message(error) =~ ~s("N")
      refute inspect(error) =~ "v-secret-71a4"
    end

    test "an env that is not a map returns an error that does not echo it" do
      assert {:error, %NimbleOptions.ValidationError{key: :env, value: nil} = error} =
               ComputeRequest.new(gpu: :h100, env: "v-secret-71a4")

      refute inspect(error) =~ "v-secret-71a4"
    end

    test "a non-string name is refused without printing the env" do
      assert {:error, %NimbleOptions.ValidationError{key: :env, value: nil} = error} =
               ComputeRequest.new(gpu: :h100, env: %{1 => "v-secret-71a4"})

      refute inspect(error) =~ "v-secret-71a4"
    end

    test "a struct as env is refused without printing it" do
      assert {:error, %NimbleOptions.ValidationError{key: :env, value: nil} = error} =
               ComputeRequest.new(gpu: :h100, env: %URI{host: "v-secret-71a4"})

      refute inspect(error) =~ "v-secret-71a4"
    end

    test "new!/1 raises the same value-free error" do
      error =
        assert_raise NimbleOptions.ValidationError, fn ->
          ComputeRequest.new!(gpu: :h100, env: %{"K" => "v-secret-71a4", "N" => 1})
        end

      assert error.key == :env
      refute inspect(error) =~ "v-secret-71a4"
    end

    test "a map of strings is accepted as before (control)" do
      assert {:ok, %ComputeRequest{env: %{"K" => "v-secret-71a4"}}} =
               ComputeRequest.new(gpu: :h100, env: %{"K" => "v-secret-71a4"})
    end
  end

  describe "s3:" do
    test "defaults to nil" do
      assert ComputeRequest.new!(gpu: :h100).s3 == nil
    end

    test "a map or a keyword list becomes a Staging" do
      assert %Staging{dataset_uri: "s3://bucket/datasets/abc/"} =
               ComputeRequest.new!(gpu: :h100, s3: @s3).s3

      assert ComputeRequest.new!(gpu: :h100, s3: Map.to_list(@s3)).s3 ==
               ComputeRequest.new!(gpu: :h100, s3: @s3).s3
    end

    test "a key id without its secret is refused on :s3, with no key value in the error" do
      assert {:error, %NimbleOptions.ValidationError{key: :s3, value: nil} = error} =
               ComputeRequest.new(gpu: :h100, s3: Map.delete(@s3, :secret_access_key))

      assert Exception.message(error) =~ ":access_key_id and :secret_access_key go together"
      refute_secrets(inspect(error))
    end

    for {name, s3, expected} <- [
          {"session token without keys",
           %{session_token: "tses-test-0d7a", dataset_uri: "s3://b/d"}, ":session_token needs"},
          {"an https dataset URI", %{dataset_uri: "https://bucket/d/"},
           ":dataset_uri must start with s3://"},
          {"an s3 URI with no bucket", %{dataset_uri: "s3:///d/"},
           ":dataset_uri must start with s3://"},
          {"an unknown key", %{dataset_uri: "s3://b/d", bucket: "b"}, "unknown key :bucket"},
          {"no URI and no URL", %{region: "auto"},
           "needs :dataset_uri, :artifact_uri, :dataset_url or :artifact_url"}
        ] do
      @s3_input s3
      @expected expected

      test "#{name} is refused on :s3" do
        assert {:error, %NimbleOptions.ValidationError{key: :s3, value: nil} = error} =
                 ComputeRequest.new(gpu: :h100, s3: @s3_input)

        assert Exception.message(error) =~ @expected
      end
    end

    test "new!/1 raises the :s3 error" do
      error =
        assert_raise NimbleOptions.ValidationError, fn ->
          ComputeRequest.new!(gpu: :h100, s3: Map.delete(@s3, :access_key_id))
        end

      assert error.key == :s3
      refute_secrets(inspect(error))
    end

    test "inspect shows the URIs and endpoint and none of the secrets" do
      text = inspect(ComputeRequest.new!(gpu: :h100, s3: @s3))

      assert text =~ "s3://bucket/datasets/abc/"
      assert text =~ "https://t3.storage.dev"
      refute_secrets(text)
    end

    test "an env: variable that s3: also sets is refused, naming it and no value" do
      error =
        assert_raise NimbleOptions.ValidationError, fn ->
          ComputeRequest.new!(
            gpu: :h100,
            env: %{"AWS_ACCESS_KEY_ID" => "tid-env-77c3"},
            s3: @s3
          )
        end

      assert error.key == :s3
      assert Exception.message(error) =~ "AWS_ACCESS_KEY_ID"
      refute Exception.message(error) =~ "tid-env-77c3"
      refute_secrets(inspect(error))
    end

    test "an env: variable that s3: does not set is kept (control)" do
      req =
        ComputeRequest.new!(
          gpu: :h100,
          env: %{"WANDB_PROJECT" => "x", "AWS_SESSION_TOKEN" => "env-token"},
          s3: Map.delete(@s3, :session_token)
        )

      assert req.env == %{"WANDB_PROJECT" => "x", "AWS_SESSION_TOKEN" => "env-token"}
    end
  end

  describe "s3: presigned URLs" do
    @get_sig "getsig-5d0c91"
    @put_sig "putsig-a7e3b2"
    @get_url "https://bucket.s3.amazonaws.com/d.tar.gz?X-Amz-Signature=#{@get_sig}"
    @put_url "https://bucket.s3.amazonaws.com/a.tar.gz?X-Amz-Signature=#{@put_sig}"

    defp refute_signatures(text) do
      refute text =~ @get_sig
      refute text =~ @put_sig
    end

    test "inspect of the request shows neither URL's signature" do
      req = ComputeRequest.new!(gpu: :h100, s3: %{dataset_url: @get_url, artifact_url: @put_url})

      # Control: the URLs did reach the request.
      assert ComputeRequest.container_env(req)["ATLAS_DATASET_URL"] == @get_url
      text = inspect(req, limit: :infinity, printable_limit: :infinity)
      assert text =~ "Staging"
      refute_signatures(text)
    end

    for {name, url} <- [
          {"an ftp URL", "ftp://x/d?sig=getsig-5d0c91"},
          {"a URL with no host", "https://"}
        ] do
      @url url
      test "#{name} is refused on :s3 with no URL in the error" do
        assert {:error, %NimbleOptions.ValidationError{key: :s3, value: nil} = error} =
                 ComputeRequest.new(gpu: :h100, s3: %{dataset_url: @url, artifact_url: @put_url})

        assert Exception.message(error) =~ ":dataset_url must be an http:// or https:// URL"
        refute_signatures(inspect(error))
      end
    end

    test "an artifact URL alone is valid" do
      assert {:ok, %ComputeRequest{s3: %Staging{}} = req} =
               ComputeRequest.new(gpu: :h100, s3: %{artifact_url: @put_url})

      assert ComputeRequest.container_env(req) == %{"ATLAS_ARTIFACT_URL" => @put_url}
    end

    test "an empty s3: is still refused" do
      assert {:error, %NimbleOptions.ValidationError{key: :s3, value: nil}} =
               ComputeRequest.new(gpu: :h100, s3: %{})
    end

    test "an env: ATLAS_DATASET_URL beside s3: dataset_url is refused, naming it and no value" do
      assert {:error, %NimbleOptions.ValidationError{key: :s3} = error} =
               ComputeRequest.new(
                 gpu: :h100,
                 env: %{"ATLAS_DATASET_URL" => "https://x/?sig=envsig-31f0"},
                 s3: %{dataset_url: @get_url}
               )

      assert Exception.message(error) =~ "ATLAS_DATASET_URL"
      refute inspect(error) =~ "envsig-31f0"
      refute_signatures(inspect(error))
    end
  end

  describe "container_env/1" do
    test "is env plus the staging variables" do
      req =
        ComputeRequest.new!(
          gpu: :h100,
          env: %{"WANDB_PROJECT" => "x"},
          s3: %{dataset_uri: "s3://bucket/d/"}
        )

      assert ComputeRequest.container_env(req) == %{
               "WANDB_PROJECT" => "x",
               "ATLAS_DATASET_URI" => "s3://bucket/d/"
             }
    end

    test "with no s3: is env alone" do
      req = ComputeRequest.new!(gpu: :h100, env: %{"WANDB_PROJECT" => "x"})
      assert ComputeRequest.container_env(req) == %{"WANDB_PROJECT" => "x"}
    end

    test "refuses a hand-built request whose s3 is a raw map, without printing it" do
      req = Map.put(ComputeRequest.new!(gpu: :h100), :s3, @s3)
      error = assert_raise ArgumentError, fn -> ComputeRequest.container_env(req) end
      refute_secrets(Exception.message(error))
    end
  end

  describe "input shapes that are not keyword opts" do
    test "a string key is refused without printing its value" do
      assert {:error, %NimbleOptions.ValidationError{value: nil} = error} =
               ComputeRequest.new(%{:gpu => :h100, "s3" => @s3})

      assert Exception.message(error) =~ "atom keys"
      refute_secrets(inspect(error))
    end

    test "a non-keyword pair in a list is refused without printing it" do
      assert {:error, %NimbleOptions.ValidationError{value: nil} = error} =
               ComputeRequest.new([gpu: :h100] ++ [{"s3", @s3}])

      refute_secrets(inspect(error))
    end

    test "a tuple instead of opts is refused without printing it" do
      assert {:error, %NimbleOptions.ValidationError{value: nil} = error} =
               ComputeRequest.new({:s3, @s3})

      refute_secrets(inspect(error))
    end

    test "a map with atom keys still works (control)" do
      assert {:ok, %ComputeRequest{s3: %Staging{}}} = ComputeRequest.new(%{gpu: :h100, s3: @s3})
    end
  end
end
