defmodule ExAtlas.S3.Config do
  @moduledoc """
  Where `ExAtlas.S3` sends its requests, and the keys it signs them with.
  Build one with `ExAtlas.S3.config!/1`.

  `inspect/1` prints the bucket, endpoint, region and addressing style. The
  two keys sit in `ExAtlas.Secret` from the moment `config!/1` takes them, so
  neither `inspect/1`, a crash report nor an error prints them.
  """

  alias ExAtlas.Secret

  @derive {Inspect, only: [:bucket, :endpoint, :region, :path_style]}
  @enforce_keys [:bucket, :endpoint, :region, :access_key_id, :secret_access_key]
  defstruct [
    :bucket,
    :endpoint,
    :region,
    :access_key_id,
    :secret_access_key,
    path_style: false,
    req_options: []
  ]

  @type t :: %__MODULE__{
          bucket: String.t(),
          endpoint: String.t(),
          region: String.t(),
          access_key_id: Secret.t(),
          secret_access_key: Secret.t(),
          path_style: boolean(),
          req_options: keyword()
        }

  @keys [
    :bucket,
    :endpoint,
    :region,
    :access_key_id,
    :secret_access_key,
    :path_style,
    :req_options
  ]

  @variables [
    endpoint: "AWS_ENDPOINT_URL_S3",
    region: "AWS_REGION",
    access_key_id: "AWS_ACCESS_KEY_ID",
    secret_access_key: "AWS_SECRET_ACCESS_KEY"
  ]

  # Req options that change how a request travels, never where it goes or
  # what it signs. Everything else (`:base_url`, `:url`, `:params`, `:headers`,
  # `:auth`, `:aws_sigv4`, `:redirect`, ...) could send the signed request, or
  # the body, somewhere the bucket's owner did not choose.
  @req_options [
    :plug,
    :adapter,
    :finch,
    :connect_options,
    :inet6,
    :pool_timeout,
    :receive_timeout,
    :pool_max_idle_time,
    :retry,
    :retry_delay,
    :retry_log_level,
    :max_retries
  ]

  @doc false
  @spec new(term()) :: {:ok, t()} | {:error, NimbleOptions.ValidationError.t()}
  def new(opts) do
    with :ok <- check_keyword(opts),
         :ok <- check_known(opts),
         {:ok, bucket} <- bucket(opts),
         {:ok, endpoint} <- endpoint(opts),
         {:ok, region} <- region(opts, endpoint),
         {:ok, key_id} <- secret(opts, :access_key_id),
         {:ok, secret_key} <- secret(opts, :secret_access_key),
         {:ok, path_style} <- path_style(opts),
         {:ok, req_options} <- req_options(opts) do
      {:ok,
       %__MODULE__{
         bucket: bucket,
         endpoint: endpoint || "https://s3.#{region}.amazonaws.com",
         region: region,
         access_key_id: key_id,
         secret_access_key: secret_key,
         path_style: path_style,
         req_options: req_options
       }}
    end
  end

  # `Keyword` raises on an improper list with its tail, which can be a key, in
  # the stacktrace, so the shape is walked by hand first.
  defp check_keyword(opts) do
    if keyword?(opts), do: :ok, else: invalid(:opts, "expected a keyword list with atom keys")
  end

  defp keyword?([]), do: true
  defp keyword?([{key, _value} | rest]) when is_atom(key), do: keyword?(rest)
  defp keyword?(_other), do: false

  defp check_known(opts) do
    case Enum.find(opts, fn {key, _} -> key not in @keys end) do
      nil -> :ok
      {key, _} -> invalid(key, "unknown option; known options are #{inspect(@keys)}")
    end
  end

  # S3's bucket naming rules. The name becomes a host name label with
  # virtual-hosted addressing, so nothing else may pass.
  defp bucket(opts) do
    case Keyword.get(opts, :bucket) do
      nil ->
        invalid(:bucket, "required")

      bucket when is_binary(bucket) ->
        if bucket =~ ~r/\A[a-z0-9][a-z0-9.\-]{1,61}[a-z0-9]\z/,
          do: {:ok, bucket},
          else:
            invalid(
              :bucket,
              "must be 3 to 63 lowercase letters, digits, dots or hyphens, " <>
                "starting and ending with a letter or digit"
            )

      _other ->
        invalid(:bucket, "must be a string")
    end
  end

  defp endpoint(opts) do
    case option_or_env(opts, :endpoint) do
      nil -> {:ok, nil}
      url when is_binary(url) -> check_endpoint(url)
      _other -> endpoint_error()
    end
  end

  defp check_endpoint(url) do
    case URI.parse(url) do
      %URI{userinfo: userinfo} when userinfo != nil ->
        invalid(
          :endpoint,
          "must not carry user info; pass the keys as :access_key_id and :secret_access_key"
        )

      %URI{scheme: scheme, host: host, path: path, query: nil, fragment: nil}
      when scheme in ["http", "https"] and is_binary(host) and host != "" and
             path in [nil, "", "/"] ->
        if host =~ ~r/\A[A-Za-z0-9.\-]+\z/,
          do: {:ok, String.trim_trailing(url, "/")},
          else: endpoint_error()

      _other ->
        endpoint_error()
    end
  end

  defp endpoint_error,
    do: invalid(:endpoint, "must be an http:// or https:// URL with a host and no path")

  # Fly's Tigris sets `AWS_REGION=auto`. AWS itself needs a real region, so
  # with no endpoint the default is AWS's own default region.
  defp region(opts, endpoint) do
    case option_or_env(opts, :region) do
      nil when endpoint == nil -> {:ok, "us-east-1"}
      nil -> {:ok, "auto"}
      region when is_binary(region) -> check_region(region)
      _other -> region_error()
    end
  end

  defp check_region(region) do
    if region =~ ~r/\A[a-z0-9\-]{1,64}\z/, do: {:ok, region}, else: region_error()
  end

  defp region_error, do: invalid(:region, "must be lowercase letters, digits and hyphens")

  defp secret(opts, key) do
    variable = Keyword.fetch!(@variables, key)

    case opts |> option_or_env(key) |> Secret.reveal() do
      nil ->
        invalid(key, "required; pass #{inspect(key)} or set #{variable}")

      value when is_binary(value) and value != "" ->
        if String.valid?(value) and not String.match?(value, ~r/[[:cntrl:]]/u),
          do: {:ok, Secret.wrap(value)},
          else: invalid(key, "must be printable text")

      _other ->
        invalid(key, "must be a non-empty string or an ExAtlas.Secret of one")
    end
  end

  defp path_style(opts) do
    case Keyword.get(opts, :path_style, false) do
      value when is_boolean(value) -> {:ok, value}
      _other -> invalid(:path_style, "must be a boolean")
    end
  end

  defp req_options(opts) do
    req_options = Keyword.get(opts, :req_options, [])

    cond do
      not keyword?(req_options) ->
        invalid(:req_options, "expected a keyword list")

      bad = Enum.find(req_options, fn {key, _} -> key not in @req_options end) ->
        invalid(
          :req_options,
          "#{inspect(elem(bad, 0))} is not allowed; allowed options are #{inspect(@req_options)}"
        )

      Keyword.has_key?(req_options, :connect_options) and
          not connect_options?(Keyword.get(req_options, :connect_options)) ->
        invalid(
          :req_options,
          ":connect_options may hold only :timeout, :protocols and " <>
            ":transport_opts with :cacertfile or :cacerts"
        )

      true ->
        {:ok, req_options}
    end
  end

  # `:proxy`, `:hostname` and `verify: :verify_none` would send the signed
  # request somewhere else, or to a host whose certificate nothing checked.
  defp connect_options?(opts) do
    keyword?(opts) and
      Enum.all?(opts, fn
        {key, _} when key in [:timeout, :protocols] -> true
        {:transport_opts, transport} -> transport_opts?(transport)
        _other -> false
      end)
  end

  defp transport_opts?(opts),
    do: keyword?(opts) and Enum.all?(opts, fn {key, _} -> key in [:cacertfile, :cacerts] end)

  # An empty variable counts as unset, as in a shell.
  defp option_or_env(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} ->
        value

      :error ->
        case System.get_env(Keyword.fetch!(@variables, key)) do
          "" -> nil
          value -> value
        end
    end
  end

  # The message names the option and the rule, never the value, which can be
  # a key.
  defp invalid(key, detail) do
    {:error,
     %NimbleOptions.ValidationError{
       key: key,
       value: nil,
       message: "invalid value for #{inspect(key)} option: #{detail}"
     }}
  end
end
