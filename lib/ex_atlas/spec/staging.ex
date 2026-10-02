defmodule ExAtlas.Spec.Staging do
  @moduledoc """
  Where a container reads its dataset and writes its artifacts, and the
  credentials to do it: the `s3:` option of `ExAtlas.Spec.ComputeRequest`.

      s3: %{
        endpoint: "https://t3.storage.dev",
        region: "auto",
        access_key_id: "tid_...",
        secret_access_key: "tsec_...",
        dataset_uri: "s3://bucket/datasets/abc/",
        artifact_uri: "s3://bucket/artifacts/run-123/"
      }

  | Key | Variable(s) in the container |
  |---|---|
  | `:endpoint` | `AWS_ENDPOINT_URL_S3` |
  | `:region` | `AWS_REGION`, `AWS_DEFAULT_REGION` |
  | `:access_key_id` | `AWS_ACCESS_KEY_ID` |
  | `:secret_access_key` | `AWS_SECRET_ACCESS_KEY` |
  | `:session_token` | `AWS_SESSION_TOKEN` |
  | `:dataset_uri` | `ATLAS_DATASET_URI` |
  | `:artifact_uri` | `ATLAS_ARTIFACT_URI` |

  A key left out sets no variable; no `:endpoint` means AWS S3 itself. Only the
  S3 endpoint variable is set, not the global `AWS_ENDPOINT_URL`, which would
  also redirect every other AWS service the container calls.

  `inspect/1` prints the endpoint, region and URIs, never a credential.
  Validation errors name the key and the rule, never a value.
  """

  @derive {Inspect, only: [:endpoint, :region, :dataset_uri, :artifact_uri]}
  defstruct endpoint: nil,
            region: nil,
            access_key_id: nil,
            secret_access_key: nil,
            session_token: nil,
            dataset_uri: nil,
            artifact_uri: nil

  @type t :: %__MODULE__{
          endpoint: String.t() | nil,
          region: String.t() | nil,
          access_key_id: String.t() | nil,
          secret_access_key: String.t() | nil,
          session_token: String.t() | nil,
          dataset_uri: String.t() | nil,
          artifact_uri: String.t() | nil
        }

  @keys [
    :endpoint,
    :region,
    :access_key_id,
    :secret_access_key,
    :session_token,
    :dataset_uri,
    :artifact_uri
  ]

  @variables [
    endpoint: ["AWS_ENDPOINT_URL_S3"],
    region: ["AWS_REGION", "AWS_DEFAULT_REGION"],
    access_key_id: ["AWS_ACCESS_KEY_ID"],
    secret_access_key: ["AWS_SECRET_ACCESS_KEY"],
    session_token: ["AWS_SESSION_TOKEN"],
    dataset_uri: ["ATLAS_DATASET_URI"],
    artifact_uri: ["ATLAS_ARTIFACT_URI"]
  ]

  @doc """
  Validate `s3:` input, a map or a keyword list, into a `Staging`.

  `nil` stays `nil`. An error is a `NimbleOptions.ValidationError` with
  `key: :s3` and `value: nil`.
  """
  @spec new(t() | map() | keyword() | nil) ::
          {:ok, t() | nil} | {:error, NimbleOptions.ValidationError.t()}
  def new(nil), do: {:ok, nil}
  def new(%__MODULE__{} = staging), do: staging |> Map.from_struct() |> new()

  def new(input) when (is_map(input) and not is_struct(input)) or is_list(input) do
    with {:ok, fields} <- fields(input),
         :ok <- check_values(fields),
         staging = struct!(__MODULE__, fields),
         :ok <- check_endpoint(staging.endpoint),
         :ok <- check_uri(:dataset_uri, staging.dataset_uri),
         :ok <- check_uri(:artifact_uri, staging.artifact_uri),
         :ok <- check_credentials(staging),
         :ok <- check_has_uri(staging) do
      {:ok, staging}
    end
  end

  def new(_input), do: error("expected a map or a keyword list")

  @doc """
  The container variables `staging` sets, by name.

  Raises `ArgumentError` for anything `new/1` did not build, and never prints
  it: a raw `s3:` map holds the credentials.
  """
  @spec env(t() | nil) :: %{String.t() => String.t()}
  def env(nil), do: %{}

  def env(%__MODULE__{} = staging) do
    for {key, names} <- @variables,
        value = Map.fetch!(staging, key),
        value != nil,
        name <- names,
        into: %{},
        do: {name, value}
  end

  def env(_other) do
    raise ArgumentError,
          "ComputeRequest.s3 must be nil or an ExAtlas.Spec.Staging from Staging.new/1 " <>
            "or ComputeRequest.new/1"
  end

  # --- validation ---

  defp fields(input) do
    pairs = Enum.to_list(input)

    cond do
      not Enum.all?(pairs, &match?({key, _} when is_atom(key), &1)) ->
        error("keys must be atoms")

      unknown = Enum.find(pairs, fn {key, _} -> key not in @keys end) ->
        error("unknown key #{inspect(elem(unknown, 0))}; known keys are #{inspect(@keys)}")

      duplicate = duplicate_key(pairs) ->
        error("duplicate key #{inspect(duplicate)}")

      true ->
        {:ok, pairs}
    end
  end

  defp duplicate_key(pairs) do
    pairs
    |> Enum.map(&elem(&1, 0))
    |> Enum.frequencies()
    |> Enum.find_value(fn {key, count} -> if count > 1, do: key end)
  end

  defp check_values(fields) do
    case Enum.find(fields, fn {_key, value} -> not (is_nil(value) or non_empty?(value)) end) do
      nil -> :ok
      {key, _value} -> error("#{inspect(key)} must be a non-empty string")
    end
  end

  defp non_empty?(value), do: is_binary(value) and value != ""

  defp check_endpoint(nil), do: :ok

  defp check_endpoint(endpoint) do
    case URI.parse(endpoint) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and host not in [nil, ""] ->
        :ok

      _other ->
        error(":endpoint must be an http:// or https:// URL")
    end
  end

  defp check_uri(_key, nil), do: :ok

  defp check_uri(key, "s3://" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [bucket | _] when bucket != "" -> :ok
      _no_bucket -> uri_error(key)
    end
  end

  defp check_uri(key, _other), do: uri_error(key)

  defp uri_error(key), do: error("#{inspect(key)} must start with s3:// and name a bucket")

  defp check_credentials(%__MODULE__{access_key_id: id, secret_access_key: secret})
       when is_nil(id) != is_nil(secret),
       do: error(":access_key_id and :secret_access_key go together: give both or neither")

  defp check_credentials(%__MODULE__{session_token: token, access_key_id: nil})
       when is_binary(token),
       do: error(":session_token needs :access_key_id and :secret_access_key")

  defp check_credentials(_staging), do: :ok

  defp check_has_uri(%__MODULE__{dataset_uri: nil, artifact_uri: nil}),
    do: error("needs :dataset_uri or :artifact_uri")

  defp check_has_uri(_staging), do: :ok

  defp error(detail) do
    {:error,
     %NimbleOptions.ValidationError{
       key: :s3,
       value: nil,
       message: "invalid value for :s3 option: " <> detail
     }}
  end
end
