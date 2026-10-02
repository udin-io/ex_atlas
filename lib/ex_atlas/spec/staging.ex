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

  Or, with no storage key on the pod, two URLs you presign on your side:

      s3: %{dataset_url: presigned_get, artifact_url: presigned_put}

  | Key | Variable(s) in the container |
  |---|---|
  | `:endpoint` | `AWS_ENDPOINT_URL_S3` |
  | `:region` | `AWS_REGION`, `AWS_DEFAULT_REGION` |
  | `:access_key_id` | `AWS_ACCESS_KEY_ID` |
  | `:secret_access_key` | `AWS_SECRET_ACCESS_KEY` |
  | `:session_token` | `AWS_SESSION_TOKEN` |
  | `:dataset_uri` | `ATLAS_DATASET_URI` |
  | `:artifact_uri` | `ATLAS_ARTIFACT_URI` |
  | `:dataset_url` | `ATLAS_DATASET_URL` |
  | `:artifact_url` | `ATLAS_ARTIFACT_URL` |

  `s3:` needs at least one of the two URIs and the two URLs. ExAtlas never
  presigns and never reads a URL's expiry; see the data staging guide.

  A key left out sets no variable; no `:endpoint` means AWS S3 itself. Only the
  S3 endpoint variable is set, not the global `AWS_ENDPOINT_URL`, which would
  also redirect every other AWS service the container calls.

  `inspect/1` prints the endpoint, region and URIs, never a credential or a
  presigned URL: a presigned URL grants access to whoever holds it until it
  expires. The three credential fields and the two URL fields hold an
  `ExAtlas.Secret`, so a printer that skips `Inspect` prints none of them
  either. Validation errors name the key and the
  rule, never a value.
  """

  alias ExAtlas.Secret

  @derive {Inspect, only: [:endpoint, :region, :dataset_uri, :artifact_uri]}
  defstruct endpoint: nil,
            region: nil,
            access_key_id: nil,
            secret_access_key: nil,
            session_token: nil,
            dataset_uri: nil,
            artifact_uri: nil,
            dataset_url: nil,
            artifact_url: nil

  @type t :: %__MODULE__{
          endpoint: String.t() | nil,
          region: String.t() | nil,
          access_key_id: Secret.t() | nil,
          secret_access_key: Secret.t() | nil,
          session_token: Secret.t() | nil,
          dataset_uri: String.t() | nil,
          artifact_uri: String.t() | nil,
          dataset_url: Secret.t() | nil,
          artifact_url: Secret.t() | nil
        }

  @keys [
    :endpoint,
    :region,
    :access_key_id,
    :secret_access_key,
    :session_token,
    :dataset_uri,
    :artifact_uri,
    :dataset_url,
    :artifact_url
  ]

  @public [:endpoint, :region, :dataset_uri, :artifact_uri]

  @variables [
    endpoint: ["AWS_ENDPOINT_URL_S3"],
    region: ["AWS_REGION", "AWS_DEFAULT_REGION"],
    access_key_id: ["AWS_ACCESS_KEY_ID"],
    secret_access_key: ["AWS_SECRET_ACCESS_KEY"],
    session_token: ["AWS_SESSION_TOKEN"],
    dataset_uri: ["ATLAS_DATASET_URI"],
    artifact_uri: ["ATLAS_ARTIFACT_URI"],
    dataset_url: ["ATLAS_DATASET_URL"],
    artifact_url: ["ATLAS_ARTIFACT_URL"]
  ]

  @doc """
  Validate `s3:` input, a map or a keyword list, into a `Staging`.

  `nil` stays `nil`. An error is a `NimbleOptions.ValidationError` with
  `key: :s3` and `value: nil`.
  """
  @spec new(t() | map() | keyword() | nil) ::
          {:ok, t() | nil} | {:error, NimbleOptions.ValidationError.t()}
  def new(nil), do: {:ok, nil}

  def new(%__MODULE__{} = staging),
    do: staging |> Map.from_struct() |> Map.new(fn {k, v} -> {k, Secret.reveal(v)} end) |> new()

  def new(input) when (is_map(input) and not is_struct(input)) or is_list(input) do
    with {:ok, fields} <- fields(input),
         :ok <- check_values(fields),
         staging = struct!(__MODULE__, fields),
         :ok <- check_http_url(:endpoint, staging.endpoint),
         :ok <- check_uri(:dataset_uri, staging.dataset_uri),
         :ok <- check_uri(:artifact_uri, staging.artifact_uri),
         :ok <- check_presigned(:dataset_url, staging.dataset_url),
         :ok <- check_presigned(:artifact_url, staging.artifact_url),
         :ok <- check_credentials(staging),
         :ok <- check_has_location(staging) do
      {:ok, seal(staging)}
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
        value = Secret.reveal(Map.fetch!(staging, key)),
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

  @doc """
  The part of `s3:` a tracking record may keep: the endpoint, region and URIs
  that are set, plus `credentials: :not_stored`.

  Only a `Staging` from `new/1` gives up its fields. Any other value gives the
  marker alone, since nothing checked it for a credential.
  """
  @spec scrub(term()) :: map()
  def scrub(%__MODULE__{} = staging) do
    for key <- @public,
        value = Map.fetch!(staging, key),
        value != nil,
        into: %{credentials: :not_stored},
        do: {key, value}
  end

  def scrub(_unvalidated), do: %{credentials: :not_stored}

  @doc "Whether `s3` is a record's scrubbed `s3:`, from `scrub/1`."
  @spec not_stored?(term()) :: boolean()
  def not_stored?(%{credentials: :not_stored}), do: true
  def not_stored?(_s3), do: false

  # A presigned URL is a bearer credential until it expires.
  @sealed [:access_key_id, :secret_access_key, :session_token, :dataset_url, :artifact_url]

  defp seal(staging) do
    Enum.reduce(@sealed, staging, fn key, acc -> Map.update!(acc, key, &Secret.wrap/1) end)
  end

  # --- validation ---

  defp fields(input) do
    pairs = if is_map(input), do: Map.to_list(input), else: input

    cond do
      not proper_pairs?(pairs) ->
        error("expected a map or a keyword list")

      not Enum.all?(pairs, fn {key, _} -> is_atom(key) end) ->
        error("keys must be atoms")

      {:credentials, :not_stored} in pairs ->
        error(
          "credentials: :not_stored marks a tracking record's :s3, which never holds the " <>
            "credentials or presigned URLs; pass the full :s3 again"
        )

      unknown = Enum.find(pairs, fn {key, _} -> key not in @keys end) ->
        error("unknown key #{inspect(elem(unknown, 0))}; known keys are #{inspect(@keys)}")

      duplicate = duplicate_key(pairs) ->
        error("duplicate key #{inspect(duplicate)}")

      true ->
        {:ok, pairs}
    end
  end

  # `Enum` raises on an improper list, with its tail (a credential) in the
  # stacktrace, so the shape is walked by hand first.
  defp proper_pairs?([]), do: true
  defp proper_pairs?([{_key, _value} | rest]), do: proper_pairs?(rest)
  defp proper_pairs?(_other), do: false

  defp duplicate_key(pairs) do
    pairs
    |> Enum.map(&elem(&1, 0))
    |> Enum.frequencies()
    |> Enum.find_value(fn {key, count} -> if count > 1, do: key end)
  end

  defp check_values(fields) do
    cond do
      bad = Enum.find(fields, fn {_key, value} -> not (is_nil(value) or non_empty?(value)) end) ->
        error("#{inspect(elem(bad, 0))} must be a non-empty string")

      # Before the regex, which raises on invalid UTF-8 with the value in its
      # stacktrace.
      bad =
          Enum.find(fields, fn {_key, value} -> is_binary(value) and not String.valid?(value) end) ->
        error("#{inspect(elem(bad, 0))} must be valid UTF-8")

      bad = Enum.find(fields, fn {_key, value} -> is_binary(value) and control?(value) end) ->
        error("#{inspect(elem(bad, 0))} must not hold control characters")

      true ->
        :ok
    end
  end

  # A newline in a variable's value can end it early in a shell's `env` dump or
  # an `.env` file the container writes.
  defp control?(value), do: String.match?(value, ~r/[[:cntrl:]]/u)

  defp non_empty?(value), do: is_binary(value) and value != ""

  # The endpoint and the presigned URLs: plain http is allowed, for a local
  # MinIO.
  defp check_http_url(_key, nil), do: :ok

  defp check_http_url(key, url) do
    case URI.parse(url) do
      %URI{userinfo: userinfo} when userinfo != nil ->
        error(userinfo_message(key))

      %URI{scheme: scheme, host: host, port: port}
      when scheme in ["http", "https"] and is_binary(host) and port in 1..65_535 ->
        if host =~ ~r/\A[A-Za-z0-9.\-\[\]:]+\z/, do: :ok, else: http_url_error(key)

      _other ->
        http_url_error(key)
    end
  end

  defp userinfo_message(:endpoint),
    do:
      ":endpoint must not carry user info; pass the keys as :access_key_id and :secret_access_key"

  defp userinfo_message(key), do: "#{inspect(key)} must not carry user info"

  defp http_url_error(key), do: error("#{inspect(key)} must be an http:// or https:// URL")

  # After the host, only RFC 3986 characters, without `[ ]`: curl reads `{ }`
  # and `[ ]` as a glob and prints the whole URL in its error. A URL with no
  # object path makes `curl -T` append the file name to it.
  defp check_presigned(_key, nil), do: :ok

  defp check_presigned(key, url) do
    with :ok <- check_http_url(key, url) do
      %URI{path: path, query: query} = URI.parse(url)

      cond do
        not (url =~ ~r/\A[\x21-\x7E]+\z/ and
                 "#{path}?#{query}" =~ ~r/\A[A-Za-z0-9\-._~:\/?#@!$&'()*+,;=%]*\z/) ->
          error("#{inspect(key)} must hold only URL characters (RFC 3986, no braces or brackets)")

        path in [nil, "", "/"] ->
          error("#{inspect(key)} must name an object: a path after the host")

        true ->
          :ok
      end
    end
  end

  defp check_uri(_key, nil), do: :ok

  defp check_uri(key, "s3://" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [bucket | _] -> if bucket =~ ~r/\A[A-Za-z0-9._-]+\z/, do: :ok, else: uri_error(key)
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

  defp check_has_location(%__MODULE__{
         dataset_uri: nil,
         artifact_uri: nil,
         dataset_url: nil,
         artifact_url: nil
       }),
       do: error("needs :dataset_uri, :artifact_uri, :dataset_url or :artifact_url")

  defp check_has_location(_staging), do: :ok

  defp error(detail) do
    {:error,
     %NimbleOptions.ValidationError{
       key: :s3,
       value: nil,
       message: "invalid value for :s3 option: " <> detail
     }}
  end
end
