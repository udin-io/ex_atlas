defmodule ExAtlas.S3 do
  @moduledoc """
  Read and write objects in an S3-compatible bucket: Tigris, AWS S3, or a
  store on your own network such as MinIO.

      s3 = ExAtlas.S3.config!(bucket: "media", endpoint: "https://t3.storage.dev")
      ExAtlas.S3.put(s3, "events/1/thumb.jpg", jpeg, content_type: "image/jpeg")
      # => :ok
      ExAtlas.S3.get(s3, "events/1/missing.jpg")
      # => {:error, %ExAtlas.Error{kind: :not_found}}

  Every call signs its request with AWS Signature Version 4 through Req's
  `:aws_sigv4` option, and returns `{:error, %ExAtlas.Error{}}` on failure:

    * `:not_found`: the key or the bucket does not exist (HTTP 404, or S3's
      `NoSuchKey` code);
    * `:forbidden`: the keys may not do this (HTTP 403);
    * `:unauthorized`, `:rate_limited`, `:timeout`, `:provider`: other HTTP
      answers, a redirect included, since ExAtlas never follows one with a
      signed request;
    * `:transport`: the store did not answer, a socket timeout included;
    * `:validation`: ExAtlas refused the input before any request.

  An error's `raw` holds S3's error code and request id and nothing else of
  the body: an S3 error body can quote the access key id and the request it
  refused.

  ## Options for `config!/1`

    * `:bucket` (required): the bucket name.
    * `:endpoint`: the store's URL, such as `"https://t3.storage.dev"` for
      Tigris or `"http://minio.internal:9000"`. Defaults to the
      `AWS_ENDPOINT_URL_S3` variable, which Fly's Tigris extension sets, then
      to AWS's endpoint for the region.
    * `:region`: defaults to `AWS_REGION`, then to `"auto"` with an endpoint
      (Tigris's region) or `"us-east-1"` without one.
    * `:access_key_id`, `:secret_access_key` (required): strings or
      `ExAtlas.Secret`s. Default to `AWS_ACCESS_KEY_ID` and
      `AWS_SECRET_ACCESS_KEY`. An empty variable counts as unset.
    * `:path_style`: `false` (the default) puts the bucket in the host name
      (`media.t3.storage.dev/key`); `true` puts it in the path
      (`minio.internal:9000/media/key`). Tigris serves buckets made since
      February 2025 only on the host name. MinIO needs `true` unless it is set
      up with a domain for virtual hosts. A bucket name with dots breaks TLS
      host checks on the host-name style, so give such a bucket `true`.
    * `:req_options`: Req options merged into each request, limited to
      timeouts, retry settings, `:plug` and `:adapter` (tests, your own code)
      and `:connect_options` with only `:timeout`, `:protocols` and
      `transport_opts: [cacertfile: ..]` or `[cacerts: ..]`, for a store with
      its own CA. Nothing that changes the host, the proxy or certificate
      checks passes.

  A missing bucket or key, or any invalid option, raises
  `NimbleOptions.ValidationError` naming the option and its variable, never
  its value.

  ## Keys

  A key is a non-empty UTF-8 string of at most 1,024 bytes (S3's limit, in
  bytes) with no control characters. It must not start with `/`, and no
  segment between slashes may be `.` or `..`, which a proxy could resolve to
  another key. Each segment is percent-escaped and `/` kept, so a key with a
  space, `+`, `%`, `?` or `#` reaches the object of that exact name.
  """

  alias ExAtlas.Error
  alias ExAtlas.S3.{Config, XML}

  @max_key_bytes 1024
  @delete_batch 1000
  # 1,000 pages of 1,000 keys: a million objects under one folder.
  @max_list_pages 1000

  @typedoc "A configured bucket, from `config!/1`."
  @type t :: Config.t()

  @type result :: :ok | {:error, Error.t()}

  @doc "Build a bucket config. See the module doc for the options."
  @spec config(keyword()) :: {:ok, t()} | {:error, NimbleOptions.ValidationError.t()}
  def config(opts), do: Config.new(opts)

  @doc "Build a bucket config, or raise `NimbleOptions.ValidationError`."
  @spec config!(keyword()) :: t()
  def config!(opts) do
    case Config.new(opts) do
      {:ok, config} -> config
      {:error, error} -> raise error
    end
  end

  @doc """
  Store `body` (iodata) at `key`, replacing any object there.

  `content_type:` sets the object's `Content-Type`.
  """
  @spec put(t(), String.t(), iodata(), keyword()) :: result()
  def put(s3, key, body, opts \\ [])

  def put(%Config{} = s3, key, body, opts) do
    with :ok <- check_key(key),
         :ok <- check_body(body),
         {:ok, headers} <- put_headers(opts) do
      s3
      |> request(:put, key_url(s3, key), headers: headers, body: body)
      |> expect_ok(fn _response -> :ok end)
    end
  end

  def put(_s3, _key, _body, _opts), do: not_config!()

  @doc "The object's bytes, exactly as stored."
  @spec get(t(), String.t()) :: {:ok, binary()} | {:error, Error.t()}
  def get(%Config{} = s3, key) do
    with :ok <- check_key(key) do
      s3
      |> request(:get, key_url(s3, key))
      |> expect_ok(fn response -> {:ok, response.body} end)
    end
  end

  def get(_s3, _key), do: not_config!()

  @doc """
  The object's size in bytes, its ETag (without quotes) and its content type
  (`nil` when the store sends none).
  """
  @spec head(t(), String.t()) ::
          {:ok,
           %{size: non_neg_integer(), etag: String.t() | nil, content_type: String.t() | nil}}
          | {:error, Error.t()}
  def head(%Config{} = s3, key) do
    with :ok <- check_key(key) do
      s3
      |> request(:head, key_url(s3, key))
      |> expect_ok(&head_result/1)
    end
  end

  def head(_s3, _key), do: not_config!()

  @doc "Delete the object at `key`. A missing key answers `:ok`, as S3 does."
  @spec delete(t(), String.t()) :: result()
  def delete(%Config{} = s3, key) do
    with :ok <- check_key(key) do
      s3
      |> request(:delete, key_url(s3, key))
      |> missing_as_ok()
      |> expect_ok(fn _response -> :ok end)
    end
  end

  def delete(_s3, _key), do: not_config!()

  @doc """
  The names directly under the folder `prefix`, sorted: the objects' names and
  the names of the folders below, without the prefix or a trailing `/`.

  `"events/1"` and `"events/1/"` both list the folder `events/1/`, never
  `events/10/`. `""` lists the top of the bucket. Every page is read.
  """
  @spec list(t(), String.t()) :: {:ok, [String.t()]} | {:error, Error.t()}
  def list(%Config{} = s3, prefix) do
    with {:ok, folder} <- folder(prefix, allow_root: true),
         {:ok, keys, prefixes} <- list_all(s3, folder, [{"delimiter", "/"}]) do
      names =
        (keys ++ Enum.map(prefixes, &String.trim_trailing(&1, "/")))
        |> Enum.flat_map(&name_under(&1, folder))
        |> Enum.uniq()
        |> Enum.sort()

      {:ok, names}
    end
  end

  def list(_s3, _prefix), do: not_config!()

  @doc """
  Delete every object under the folder `prefix`, at any depth, and return how
  many there were.

  `"events/1"` deletes `events/1/...`, never `events/10/...`. An empty or
  rooted prefix is refused: it would empty the bucket. Every page is listed
  first, then deleted in batches of at most 1,000. A key the store refuses
  to delete comes back in the error's `raw.errors` with S3's code.
  """
  @spec delete_prefix(t(), String.t()) :: {:ok, non_neg_integer()} | {:error, Error.t()}
  def delete_prefix(%Config{} = s3, prefix) do
    with {:ok, folder} <- folder(prefix, allow_root: false),
         {:ok, keys, _prefixes} <- list_all(s3, folder, []),
         :ok <- delete_batches(s3, keys) do
      {:ok, length(keys)}
    end
  end

  def delete_prefix(_s3, _prefix), do: not_config!()

  @doc false
  # Req calls this in its `:aws_sigv4` step, so the request struct holds the
  # keys wrapped and they are revealed only while the signature is built.
  @spec sigv4_options(t()) :: keyword()
  def sigv4_options(%Config{} = s3) do
    [
      access_key_id: ExAtlas.Secret.reveal(s3.access_key_id),
      secret_access_key: ExAtlas.Secret.reveal(s3.secret_access_key),
      region: s3.region,
      service: "s3"
    ]
  end

  # --- requests ---

  defp request(%Config{} = s3, method, url, opts \\ []) do
    s3.req_options
    |> Req.new()
    |> Req.merge(
      method: method,
      url: url,
      headers: Keyword.get(opts, :headers, []),
      body: Keyword.get(opts, :body),
      aws_sigv4: {__MODULE__, :sigv4_options, [s3]},
      # A redirect would resend the signed request, and the body, to a host
      # the bucket's owner did not choose.
      redirect: false,
      # An object's bytes come back as stored: no JSON decoding, no gunzip.
      raw: true,
      decode_body: false
    )
    |> Req.request()
  end

  # Some stores answer a delete of a missing key with 404 NoSuchKey; S3 itself
  # answers 204. A missing bucket stays an error.
  defp missing_as_ok({:ok, %Req.Response{status: 404} = response} = result) do
    if error_code(response.body) == "NoSuchKey",
      do: {:ok, %{response | status: 204}},
      else: result
  end

  defp missing_as_ok(result), do: result

  defp expect_ok({:ok, %Req.Response{status: status} = response}, on_ok)
       when status in 200..299,
       do: on_ok.(response)

  defp expect_ok({:ok, %Req.Response{} = response}, _on_ok),
    do: {:error, response_error(response)}

  defp expect_ok({:error, _exception} = error, _on_ok),
    do: ExAtlas.Providers.HTTP.handle_response(error, 200, :s3)

  # The body can quote the access key id, the string to sign and the canonical
  # request, so the error keeps S3's code and request id alone.
  defp response_error(%Req.Response{status: status, body: body}) do
    {code, request_id} = error_fields(body)

    kind =
      case {code, Error.from_response(status, nil, :s3).kind} do
        {"NoSuchKey", _} -> :not_found
        {_, :unknown} -> :provider
        {_, kind} -> kind
      end

    Error.new(kind,
      provider: :s3,
      status: status,
      message: "S3 answered HTTP #{status}" <> if(code, do: " #{code}", else: ""),
      raw: %{code: code, request_id: request_id}
    )
  end

  defp error_code(body), do: body |> error_fields() |> elem(0)

  defp error_fields(body) do
    case XML.parse(body) do
      {:ok, {"Error", _} = error} ->
        {safe(XML.text(error, "Code"), ~r/\A[A-Za-z0-9.]{1,64}\z/),
         safe(XML.text(error, "RequestId"), ~r/\A[A-Za-z0-9.\-_+\/=]{1,128}\z/)}

      _other ->
        {nil, nil}
    end
  end

  defp safe(nil, _pattern), do: nil
  defp safe(text, pattern), do: if(text =~ pattern, do: text)

  defp body_error(what) do
    {:error,
     Error.new(:provider,
       provider: :s3,
       status: 200,
       message: "S3 answered with #{what}; ExAtlas withholds the body"
     )}
  end

  # --- URLs ---

  defp key_url(s3, key), do: url(s3, encode_key(key), [])

  defp url(%Config{} = s3, path, query) do
    endpoint = URI.parse(s3.endpoint)

    port =
      if endpoint.port == URI.default_port(endpoint.scheme), do: "", else: ":#{endpoint.port}"

    base =
      if s3.path_style,
        do: "#{endpoint.scheme}://#{endpoint.host}#{port}/#{s3.bucket}",
        else: "#{endpoint.scheme}://#{s3.bucket}.#{endpoint.host}#{port}"

    path =
      cond do
        path != "" -> "/" <> path
        s3.path_style -> ""
        true -> "/"
      end

    base <> path <> query_string(query)
  end

  defp encode_key(key), do: URI.encode(key, &(&1 == ?/ or URI.char_unreserved?(&1)))

  # SigV4 signs the query exactly as sent, so each name and value is escaped
  # the way it wants: everything but the unreserved characters.
  defp query_string([]), do: ""

  defp query_string(pairs) do
    "?" <>
      Enum.map_join(pairs, "&", fn {name, value} ->
        URI.encode(name, &URI.char_unreserved?/1) <>
          "=" <> URI.encode(value, &URI.char_unreserved?/1)
      end)
  end

  # --- validation ---

  defp check_key(key) when is_binary(key) and key != "" do
    cond do
      byte_size(key) > @max_key_bytes ->
        invalid("a key holds at most #{@max_key_bytes} bytes")

      not String.valid?(key) ->
        invalid("a key must be valid UTF-8")

      String.match?(key, ~r/[[:cntrl:]]/u) ->
        invalid("a key must hold no control characters")

      String.starts_with?(key, "/") ->
        invalid("a key must not start with /")

      key |> String.split("/") |> Enum.any?(&(&1 in [".", ".."])) ->
        invalid("a key must not hold a . or .. segment")

      true ->
        :ok
    end
  end

  defp check_key(_key), do: invalid("a key must be a non-empty string")

  defp folder("", allow_root: true), do: {:ok, ""}

  defp folder(prefix, _opts) do
    with :ok <- check_key(prefix) do
      {:ok, if(String.ends_with?(prefix, "/"), do: prefix, else: prefix <> "/")}
    end
  end

  defp check_body(body) when is_binary(body), do: :ok

  defp check_body(body) when is_list(body) do
    IO.iodata_length(body)
    :ok
  rescue
    ArgumentError -> invalid("the body must be iodata")
  end

  defp check_body(_body), do: invalid("the body must be iodata")

  defp put_headers(opts) do
    cond do
      not Keyword.keyword?(opts) ->
        invalid("put options must be a keyword list")

      unknown = Enum.find(opts, fn {key, _} -> key != :content_type end) ->
        invalid("unknown put option #{inspect(elem(unknown, 0))}")

      true ->
        content_type(Keyword.get(opts, :content_type))
    end
  end

  defp content_type(nil), do: {:ok, []}

  # SigV4 signs a header value trimmed, with inner runs of spaces collapsed;
  # Req signs it as given, so ExAtlas sends it in that form.
  defp content_type(type) when is_binary(type) and type != "" do
    if String.valid?(type) and not String.match?(type, ~r/[[:cntrl:]]/u),
      do: {:ok, [{"content-type", type |> String.split(" ", trim: true) |> Enum.join(" ")}]},
      else: invalid(":content_type must hold no control characters")
  end

  defp content_type(_other), do: invalid(":content_type must be a non-empty string")

  defp invalid(message),
    do: {:error, Error.new(:validation, provider: :s3, message: message)}

  @spec not_config!() :: no_return()
  defp not_config! do
    raise ArgumentError, "expected an ExAtlas.S3.Config from ExAtlas.S3.config!/1"
  end

  # --- head ---

  defp head_result(response) do
    with [length] <- Req.Response.get_header(response, "content-length"),
         {size, ""} when size >= 0 <- Integer.parse(length) do
      {:ok,
       %{
         size: size,
         etag: response |> header("etag") |> unquote_etag(),
         content_type: header(response, "content-type")
       }}
    else
      _other -> body_error("no usable content-length")
    end
  end

  defp header(response, name) do
    case Req.Response.get_header(response, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp unquote_etag(nil), do: nil
  defp unquote_etag(etag), do: etag |> String.trim_leading("\"") |> String.trim_trailing("\"")

  # --- list ---

  defp list_all(s3, folder, extra) do
    params = [{"list-type", "2"}, {"prefix", folder}] ++ extra ++ [{"encoding-type", "url"}]
    list_pages(s3, folder, params, nil, MapSet.new(), [], [])
  end

  # Pages are kept newest first and joined once at the end.
  defp list_pages(s3, folder, params, token, seen, keys, prefixes) do
    query = if token, do: params ++ [{"continuation-token", token}], else: params

    with {:ok, page} <- s3 |> request(:get, url(s3, "", query)) |> expect_ok(&list_page/1),
         :ok <- check_listed(page, folder) do
      keys = [page.keys | keys]
      prefixes = [page.prefixes | prefixes]

      cond do
        not page.truncated ->
          {:ok, join_pages(keys), join_pages(prefixes)}

        page.next in [nil, ""] ->
          body_error("a truncated list page and no continuation token")

        MapSet.member?(seen, page.next) ->
          body_error("a list page that repeats an earlier continuation token")

        MapSet.size(seen) + 1 >= @max_list_pages ->
          body_error("more than #{@max_list_pages} list pages")

        true ->
          seen = MapSet.put(seen, page.next)
          list_pages(s3, folder, params, page.next, seen, keys, prefixes)
      end
    end
  end

  defp join_pages(pages), do: pages |> Enum.reverse() |> Enum.concat()

  # A store that ignores `prefix`, or sends a key ExAtlas could not have
  # written, must not steer `delete_prefix/2` to another object.
  defp check_listed(page, folder) do
    if Enum.all?(
         page.keys ++ page.prefixes,
         &(String.starts_with?(&1, folder) and check_key(&1) == :ok)
       ),
       do: :ok,
       else: body_error("a listed key outside the folder, or not a valid key")
  end

  defp list_page(%Req.Response{body: body}) do
    with {:ok, {"ListBucketResult", _} = result} <- XML.parse(body),
         decode = decoder(XML.text(result, "EncodingType")),
         {:ok, keys} <- decode_all(XML.all(result, "Contents"), "Key", decode),
         {:ok, prefixes} <- decode_all(XML.all(result, "CommonPrefixes"), "Prefix", decode) do
      {:ok,
       %{
         keys: keys,
         prefixes: prefixes,
         truncated: XML.text(result, "IsTruncated") == "true",
         next: XML.text(result, "NextContinuationToken")
       }}
    else
      _other -> body_error("a list body ExAtlas cannot read")
    end
  end

  # With `encoding-type=url`, S3 escapes each key the way a form does (a space
  # as `+`), so a key with characters XML cannot carry still comes back. A
  # store that ignores the parameter sends keys as they are.
  defp decoder("url"), do: &URI.decode_www_form/1
  defp decoder(_none), do: & &1

  defp decode_all(elements, field, decode) do
    Enum.reduce_while(elements, {:ok, []}, fn element, {:ok, acc} ->
      case XML.text(element, field) do
        nil -> {:halt, :error}
        text -> {:cont, {:ok, [decode.(text) | acc]}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      :error -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp name_under(key, folder) do
    case key do
      <<^folder::binary>> -> []
      <<^folder::binary, name::binary>> -> [name]
      _other -> []
    end
  end

  # --- delete_prefix ---

  defp delete_batches(s3, keys) do
    keys
    |> Enum.chunk_every(@delete_batch)
    |> Enum.reduce_while({:ok, []}, fn batch, {:ok, failed} ->
      case delete_batch(s3, batch) do
        {:ok, errors} -> {:cont, {:ok, failed ++ errors}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, []} ->
        :ok

      {:ok, failed} ->
        {:error,
         Error.new(:provider,
           provider: :s3,
           status: 200,
           message: "S3 did not delete #{length(failed)} of #{length(keys)} objects",
           raw: %{errors: failed}
         )}

      {:error, _} = error ->
        error
    end
  end

  defp delete_batch(s3, keys) do
    body =
      ~s(<?xml version="1.0" encoding="UTF-8"?>) <>
        ~s(<Delete xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Quiet>true</Quiet>) <>
        Enum.map_join(keys, &"<Object><Key>#{XML.escape(&1)}</Key></Object>") <>
        "</Delete>"

    headers = [
      {"content-type", "application/xml"},
      {"content-md5", Base.encode64(:crypto.hash(:md5, body))}
    ]

    s3
    |> request(:post, url(s3, "", [{"delete", ""}]), headers: headers, body: body)
    |> expect_ok(&delete_result/1)
  end

  # S3 can answer 200 with an `Error` document when the whole request failed.
  defp delete_result(%Req.Response{body: body} = response) do
    case XML.parse(body) do
      {:ok, {"DeleteResult", _} = result} ->
        {:ok,
         for error <- XML.all(result, "Error") do
           %{
             key: XML.text(error, "Key"),
             code: safe(XML.text(error, "Code"), ~r/\A[A-Za-z0-9.]{1,64}\z/)
           }
         end}

      {:ok, {"Error", _}} ->
        {:error, response_error(response)}

      _other ->
        body_error("a delete body ExAtlas cannot read")
    end
  end
end
