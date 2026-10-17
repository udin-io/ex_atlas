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
    * `:transport`: the store did not answer or dropped the connection, a
      socket timeout included;
    * `:validation`: ExAtlas refused the input before any request, or S3
      answered 416 to a range that starts past the end;
    * `:unknown`: a local file could not be read or written.

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
  # S3's multipart limits: parts of 5 MiB to 5 GiB, the last one smaller, and
  # at most 10,000 parts.
  @min_part_size 5 * 1024 * 1024
  @max_part_size 5 * 1024 * 1024 * 1024
  @default_part_size 8 * 1024 * 1024
  @max_parts 10_000
  # An error body is read for its code alone.
  @error_body_bytes 64 * 1024
  # An upload id or ETag the store sends goes back in a query or XML body.
  @token_pattern ~r/\A[\x21-\x7e]{1,1024}\z/

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

  @doc """
  The bytes of `range` in the object, without reading the rest.

  `range` is `first..last` (inclusive, step 1), or `{:from, first}` for the
  bytes from `first` to the end. A range that runs past the end comes back
  cut to the object, and `range` in the result says which bytes came.
  `total` is the object's full size, for a player's `Content-Range`.

      ExAtlas.S3.get_range(s3, "clips/42.mp4", 0..1_048_575)
      # => {:ok, %{body: <<...>>, range: 0..1_048_575, total: 209_715_200}}

  A range that starts at or past the end is `:validation` (S3's 416
  `InvalidRange`). A store that ignores the `Range` header and starts to send
  the whole object is an error, and ExAtlas stops reading it.
  """
  @spec get_range(t(), String.t(), Range.t() | {:from, non_neg_integer()}) ::
          {:ok, %{body: binary(), range: Range.t(), total: non_neg_integer()}}
          | {:error, Error.t()}
  def get_range(%Config{} = s3, key, range) do
    with :ok <- check_key(key),
         {:ok, first, last} <- check_range(range) do
      limit = if last, do: last - first + 1, else: :infinity

      s3
      |> request(:get, key_url(s3, key),
        headers: [{"range", "bytes=#{first}-#{last}"}],
        into: collect(&range_cap(&1, first, limit))
      )
      |> expect_ok(&range_result(&1, first, last))
    end
  end

  def get_range(_s3, _key, _range), do: not_config!()

  @doc """
  Stream the object to `target` as it arrives, never holding it whole.

  `target` is a file path or a 1-arity function. A path gets the bytes in a
  hidden file beside it, renamed over the path only once the last byte is
  in, so a download that fails partway leaves no file and an existing file
  as it was. A function gets each chunk in order; after a failure partway it
  has seen the chunks before it.

  ExAtlas makes one attempt, whatever `:retry` the config sets: a retry would
  hand the function the first chunks twice. Call again to retry. It writes
  as many bytes as the store sends: `head/2` first gives the size to expect.
  If the calling process is killed partway, the hidden file stays.
  """
  @spec download(t(), String.t(), Path.t() | (binary() -> any())) :: result()
  def download(%Config{} = s3, key, target) do
    with :ok <- check_key(key),
         {:ok, sink} <- open_sink(target) do
      s3
      |> request(:get, key_url(s3, key), into: stream_to(sink), retry: false)
      |> close_sink(sink)
      |> expect_ok(fn _response -> :ok end)
    end
  end

  def download(_s3, _key, _target), do: not_config!()

  @doc """
  Store the file at `path` under `key`, reading it one part at a time.

  A file of at most `part_size` bytes goes up in one PutObject. A larger file
  goes up as a multipart upload in parts of `part_size` bytes, the last one
  smaller. If any step fails, ExAtlas aborts the upload so the store keeps
  no parts that bill, and returns the first error. An abort can fail too;
  a bucket lifecycle rule that aborts incomplete multipart uploads after a
  day or so clears what is left.

  Options:

    * `:content_type`: the object's `Content-Type`.
    * `:part_size`: bytes per part, from 5 MiB to 5 GiB (S3's limits).
      Defaults to 8 MiB. ExAtlas holds one part in memory at a time, so a
      large `:part_size` costs that much memory per upload. S3 takes at most 10,000 parts, so a file over
      10,000 parts is refused: raise `:part_size` for it.
  """
  @spec upload_file(t(), String.t(), Path.t(), keyword()) :: result()
  def upload_file(s3, key, path, opts \\ [])

  def upload_file(%Config{} = s3, key, path, opts) do
    with :ok <- check_key(key),
         {:ok, headers, part_size} <- upload_options(opts),
         {:ok, size} <- file_size(path),
         :ok <- check_parts(size, part_size) do
      if size <= part_size,
        do: put_file(s3, key, path, headers),
        else: multipart_upload(s3, key, path, headers, size, part_size)
    end
  end

  def upload_file(_s3, _key, _path, _opts), do: not_config!()

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
    |> Req.merge(Keyword.take(opts, [:into, :retry]))
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
        {_, _} when status == 416 -> :validation
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
    with :ok <- check_options(opts, [:content_type], "put") do
      content_type(Keyword.get(opts, :content_type))
    end
  end

  defp check_options(opts, allowed, call) do
    cond do
      not Keyword.keyword?(opts) ->
        invalid("#{call} options must be a keyword list")

      unknown = Enum.find(opts, fn {key, _} -> key not in allowed end) ->
        invalid("unknown #{call} option #{inspect(elem(unknown, 0))}")

      true ->
        :ok
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

  # --- get_range ---

  defp check_range(%Range{first: first, last: last, step: 1})
       when is_integer(first) and first >= 0 and last >= first,
       do: {:ok, first, last}

  defp check_range({:from, first}) when is_integer(first) and first >= 0,
    do: {:ok, first, nil}

  defp check_range(_range),
    do: invalid("a range must be first..last with 0 <= first <= last, or {:from, first}")

  # Reads the body into the response, and stops once it holds more than
  # `cap_for.(status)` bytes for a 2xx: a store that ignores `Range` must not
  # fill memory. An error body is cut at @error_body_bytes; ExAtlas reads only
  # its code from it.
  defp collect(cap_for) do
    fn {:data, data}, {request, response} ->
      cap = if response.status in 200..299, do: cap_for.(response.status), else: @error_body_bytes
      body = response.body <> data

      if cap != :infinity and byte_size(body) > cap,
        do:
          {:halt,
           {request,
            %{response | body: "", private: Map.put(response.private, :ex_atlas_overflow, true)}}},
        else: {:cont, {request, %{response | body: body}}}
    end
  end

  defp range_result(%Req.Response{status: 206, private: private} = response, first, last)
       when not is_map_key(private, :ex_atlas_overflow) do
    with [content_range] <- Req.Response.get_header(response, "content-range"),
         [_, a, b, total] <- Regex.run(~r/\Abytes (\d+)-(\d+)\/(\d+)\z/, content_range),
         {a, b, total} = {String.to_integer(a), String.to_integer(b), String.to_integer(total)},
         true <- a == first and b >= a and b < total,
         true <- if(last, do: b == last or (b < last and b == total - 1), else: b == total - 1),
         true <- byte_size(response.body) == b - a + 1 do
      {:ok, %{body: response.body, range: a..b, total: total}}
    else
      _other -> body_error("a Content-Range or body other than the range asked for")
    end
  end

  defp range_result(%Req.Response{status: 206}, _first, _last),
    do: body_error("more bytes than the range asked for")

  # A store may answer a range from 0 with the whole object, when the object is
  # no longer than the range (RFC 9110). That is the range, cut to the object.
  defp range_result(%Req.Response{status: 200, body: body, private: private}, 0, _last)
       when body != "" and not is_map_key(private, :ex_atlas_overflow),
       do: {:ok, %{body: body, range: 0..(byte_size(body) - 1), total: byte_size(body)}}

  defp range_result(%Req.Response{}, _first, _last),
    do: body_error("the whole object: the store ignored the Range header")

  # A 206 holds at most the range; a 200 to a range from 0 at most the range
  # too; any other 2xx ignored the range, and ExAtlas reads none of it.
  defp range_cap(206, _first, limit), do: limit
  defp range_cap(200, 0, limit), do: limit
  defp range_cap(_status, _first, _limit), do: 0

  # --- download ---

  defp open_sink(fun) when is_function(fun, 1), do: {:ok, {:fun, fun}}

  defp open_sink(path) when is_binary(path) and path != "" do
    dir = Path.dirname(path)
    part = Path.join(dir, ".#{Path.basename(path)}.part-#{random_suffix()}")

    with {:dir, true} <- {:dir, File.dir?(dir)},
         {:path, false} <- {:path, File.dir?(path)},
         {:ok, device} <- File.open(part, [:write, :binary, :exclusive]) do
      {:ok, {:file, path, part, device}}
    else
      {:dir, false} -> invalid("the target's folder does not exist")
      {:path, true} -> invalid("the target is a folder")
      {:error, reason} -> invalid("cannot write the target's folder (#{inspect(reason)})")
    end
  end

  defp open_sink(_target), do: invalid("the target must be a file path or a 1-arity function")

  defp random_suffix, do: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

  # A 2xx body goes to the sink; any other body is kept, cut, for its code.
  defp stream_to(sink) do
    # Only a non-2xx body reaches `collect/1`, and it caps that at @error_body_bytes.
    collect_error = collect(fn _status -> :infinity end)

    fn {:data, data}, {_request, response} = acc ->
      if response.status in 200..299,
        do: write_chunk(sink, data, acc),
        else: collect_error.({:data, data}, acc)
    end
  end

  defp write_chunk(sink, data, {request, response} = acc) do
    case write_sink(sink, data) do
      :ok ->
        {:cont, acc}

      {:error, reason} ->
        {:halt, {request, Req.Response.put_private(response, :ex_atlas_write_error, reason)}}
    end
  end

  defp write_sink({:fun, fun}, data) do
    fun.(data)
    :ok
  end

  defp write_sink({:file, _path, _part, device}, data), do: IO.binwrite(device, data)

  defp close_sink(result, {:fun, _fun}), do: sink_result(result)

  defp close_sink(result, {:file, path, part, device}) do
    closed = File.close(device)

    case {sink_result(result), closed} do
      {{:ok, %Req.Response{status: status}} = ok, :ok} when status in 200..299 ->
        case File.rename(part, path) do
          :ok -> ok
          {:error, reason} -> remove_then(part, file_error("rename", reason))
        end

      {{:ok, %Req.Response{status: status}}, {:error, reason}} when status in 200..299 ->
        remove_then(part, file_error("write", reason))

      {other, _closed} ->
        remove_then(part, other)
    end
  end

  defp remove_then(part, result) do
    _ = File.rm(part)
    result
  end

  defp sink_result({:ok, %Req.Response{private: %{ex_atlas_write_error: reason}}}),
    do: file_error("write", reason)

  defp sink_result(result), do: result

  defp file_error(action, reason) do
    {:error,
     Error.new(:unknown,
       provider: :s3,
       message: "could not #{action} the local file (#{inspect(reason)})"
     )}
  end

  # --- upload_file ---

  defp upload_options(opts) do
    with :ok <- check_options(opts, [:content_type, :part_size], "upload_file"),
         {:ok, headers} <- content_type(Keyword.get(opts, :content_type)) do
      case Keyword.get(opts, :part_size, @default_part_size) do
        size when is_integer(size) and size in @min_part_size..@max_part_size ->
          {:ok, headers, size}

        _other ->
          invalid(
            ":part_size must be #{@min_part_size}..#{@max_part_size} bytes (5 MiB to 5 GiB)"
          )
      end
    end
  end

  defp file_size(path) when is_binary(path) and path != "" do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} -> {:ok, size}
      {:ok, %File.Stat{}} -> invalid("the path is not a regular file")
      {:error, reason} -> invalid("cannot read the file (#{inspect(reason)})")
    end
  end

  defp file_size(_path), do: invalid("the path must be a non-empty string")

  defp check_parts(size, part_size) do
    if div(size + part_size - 1, part_size) > @max_parts,
      do: invalid("the file needs more than #{@max_parts} parts; raise :part_size"),
      else: :ok
  end

  defp put_file(s3, key, path, headers) do
    case File.read(path) do
      {:ok, body} ->
        s3
        |> request(:put, key_url(s3, key), headers: headers, body: body)
        |> expect_ok(fn _response -> :ok end)

      {:error, reason} ->
        file_error("read", reason)
    end
  end

  defp multipart_upload(s3, key, path, headers, size, part_size) do
    with {:ok, upload_id} <- create_upload(s3, key, headers) do
      result =
        with {:ok, etags} <- upload_parts(s3, key, upload_id, path, size, part_size) do
          complete_upload(s3, key, upload_id, etags)
        end

      if result != :ok, do: abort_upload(s3, key, upload_id)
      result
    end
  end

  defp upload_url(s3, key, query), do: url(s3, encode_key(key), query)

  defp create_upload(s3, key, headers) do
    s3
    # One attempt: a retry after a lost answer would start a second upload,
    # and the first one's parts would bill with no abort.
    |> request(:post, upload_url(s3, key, [{"uploads", ""}]), headers: headers, retry: false)
    |> expect_ok(fn %Req.Response{body: body} ->
      with {:ok, {"InitiateMultipartUploadResult", _} = result} <- XML.parse(body),
           id when is_binary(id) <- safe(XML.text(result, "UploadId"), @token_pattern) do
        {:ok, id}
      else
        _other -> body_error("a CreateMultipartUpload body ExAtlas cannot read")
      end
    end)
  end

  defp upload_parts(s3, key, upload_id, path, size, part_size) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, file} ->
        upload = %{s3: s3, key: key, id: upload_id, file: file, size: size, part_size: part_size}

        try do
          send_parts(upload, 1, 0, [])
        after
          File.close(file)
        end

      {:error, reason} ->
        file_error("read", reason)
    end
  end

  # One part in memory at a time, read from its offset in the file.
  defp send_parts(%{size: size}, _number, offset, etags) when offset >= size,
    do: {:ok, Enum.reverse(etags)}

  defp send_parts(upload, number, offset, etags) do
    length = min(upload.part_size, upload.size - offset)

    with {:ok, body} <- read_part(upload.file, offset, length),
         {:ok, etag} <- upload_part(upload, number, body) do
      send_parts(upload, number + 1, offset + length, [{number, etag} | etags])
    end
  end

  defp read_part(file, offset, length) do
    case :file.pread(file, offset, length) do
      {:ok, body} when byte_size(body) == length -> {:ok, body}
      {:error, reason} -> file_error("read", reason)
      _short -> file_error("read", :file_changed_size)
    end
  end

  defp upload_part(upload, number, body) do
    query = [{"partNumber", Integer.to_string(number)}, {"uploadId", upload.id}]

    upload.s3
    |> request(:put, upload_url(upload.s3, upload.key, query), body: body)
    |> expect_ok(&part_etag(&1, number))
  end

  defp part_etag(response, number) do
    case safe(header(response, "etag"), @token_pattern) do
      nil -> body_error("no usable ETag for part #{number}")
      etag -> {:ok, etag}
    end
  end

  defp complete_upload(s3, key, upload_id, etags) do
    body =
      ~s(<?xml version="1.0" encoding="UTF-8"?>) <>
        ~s(<CompleteMultipartUpload xmlns="http://s3.amazonaws.com/doc/2006-03-01/">) <>
        Enum.map_join(etags, fn {number, etag} ->
          "<Part><PartNumber>#{number}</PartNumber><ETag>#{XML.escape(etag)}</ETag></Part>"
        end) <>
        "</CompleteMultipartUpload>"

    s3
    |> request(:post, upload_url(s3, key, [{"uploadId", upload_id}]),
      headers: [{"content-type", "application/xml"}],
      body: body,
      # One attempt: a retry after a lost success answers NoSuchUpload, and the
      # upload would be aborted and reported failed with the object stored.
      retry: false
    )
    |> expect_ok(&complete_result/1)
  end

  # S3 sends 200 before it assembles the parts, so a failure comes back as an
  # `Error` document inside the 200.
  defp complete_result(%Req.Response{body: body} = response) do
    case XML.parse(body) do
      {:ok, {"CompleteMultipartUploadResult", _}} -> :ok
      {:ok, {"Error", _}} -> {:error, response_error(response)}
      _other -> body_error("a CompleteMultipartUpload body ExAtlas cannot read")
    end
  end

  defp abort_upload(s3, key, upload_id) do
    request(s3, :delete, upload_url(s3, key, [{"uploadId", upload_id}]))
  end
end
