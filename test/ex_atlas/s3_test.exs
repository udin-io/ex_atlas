defmodule ExAtlas.S3Test do
  use ExUnit.Case, async: true

  alias ExAtlas.Error
  alias ExAtlas.S3

  @key_id "AKIA-S3-TEST-KEY-ID-4410"
  @secret "s3-test-secret-access-key-5521"

  # A stub store. Each request it receives goes to the test process as
  # `{:request, map}`; `respond` builds the answer.
  defp stub(respond) do
    test = self()

    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(
        test,
        {:request,
         %{
           method: conn.method,
           scheme: conn.scheme,
           host: conn.host,
           port: conn.port,
           path: conn.request_path,
           query: conn.query_string,
           headers: Map.new(conn.req_headers),
           body: body
         }}
      )

      respond.(conn)
    end
  end

  defp s3(respond, opts \\ []) do
    S3.config!(
      Keyword.merge(
        [
          bucket: "media",
          endpoint: "https://t3.storage.dev",
          region: "auto",
          access_key_id: @key_id,
          secret_access_key: @secret,
          req_options: [plug: stub(respond), retry: false]
        ],
        opts
      )
    )
  end

  defp reply(conn, status, body \\ "", headers \\ []) do
    conn
    |> Plug.Conn.merge_resp_headers(headers)
    |> Plug.Conn.send_resp(status, body)
  end

  defp xml(conn, status, body),
    do: reply(conn, status, body, [{"content-type", "application/xml"}])

  defp s3_error(code, extra \\ "") do
    ~s(<?xml version="1.0" encoding="UTF-8"?>\n<Error><Code>#{code}</Code>) <>
      ~s(<Message>Something about #{code}</Message>#{extra}<RequestId>REQ-1</RequestId></Error>)
  end

  defp sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  defp query(request), do: URI.decode_query(request.query)

  describe "put/4" do
    test "PUTs the bytes to the key on the bucket's virtual host, signed with SigV4" do
      s3 = s3(&reply(&1, 200))

      assert :ok = S3.put(s3, "events/1/thumb.jpg", ["jp", "eg"], content_type: "image/jpeg")

      assert_received {:request, request}
      assert request.method == "PUT"
      assert request.scheme == :https
      assert request.host == "media.t3.storage.dev"
      assert request.path == "/events/1/thumb.jpg"
      assert request.body == "jpeg"
      assert request.headers["content-type"] == "image/jpeg"
      assert request.headers["x-amz-content-sha256"] == sha256("jpeg")
      assert request.headers["x-amz-date"] =~ ~r/\A\d{8}T\d{6}Z\z/

      assert request.headers["authorization"] =~
               ~r"\AAWS4-HMAC-SHA256 Credential=#{@key_id}/\d{8}/auto/s3/aws4_request,"

      assert request.headers["authorization"] =~ "SignedHeaders="
      refute request.headers["authorization"] =~ @secret
    end

    test "path_style: true puts the bucket in the path, for MinIO" do
      s3 = s3(&reply(&1, 200), endpoint: "http://minio.local:9000", path_style: true)

      assert :ok = S3.put(s3, "events/1/thumb.jpg", "x")

      assert_received {:request, request}
      assert request.scheme == :http
      assert request.host == "minio.local"
      assert request.port == 9000
      assert request.path == "/media/events/1/thumb.jpg"
    end

    test "the same key on a virtual-hosted endpoint with a port keeps the port" do
      s3 = s3(&reply(&1, 200), endpoint: "http://minio.local:9000")

      assert :ok = S3.put(s3, "events/1/thumb.jpg", "x")

      assert_received {:request, request}
      assert request.host == "media.minio.local"
      assert request.port == 9000
      assert request.path == "/events/1/thumb.jpg"
    end

    test "a refused write is an error" do
      s3 = s3(&xml(&1, 403, s3_error("AccessDenied")))

      assert {:error, %Error{kind: :forbidden, status: 403, raw: %{code: "AccessDenied"}}} =
               S3.put(s3, "a.jpg", "x")
    end

    test "a content type is sent trimmed, with inner spaces collapsed, as SigV4 signs it" do
      s3 = s3(&reply(&1, 200))
      assert :ok = S3.put(s3, "a.txt", "x", content_type: " text/plain;  charset=utf-8 ")
      assert_received {:request, request}
      assert request.headers["content-type"] == "text/plain; charset=utf-8"
    end

    test "a content type that could add a header is refused before any request" do
      s3 = s3(&reply(&1, 200))

      assert {:error, %Error{kind: :validation}} =
               S3.put(s3, "a.jpg", "x", content_type: "image/jpeg\r\nx-amz-acl: public-read")

      refute_received {:request, _}
    end

    test "a body that is not iodata is refused before any request" do
      s3 = s3(&reply(&1, 200))
      assert {:error, %Error{kind: :validation}} = S3.put(s3, "a.jpg", %{not: :iodata})
      refute_received {:request, _}
    end
  end

  describe "keys" do
    test "each path segment is escaped and / is kept" do
      for {key, path} <- [
            {"a b.jpg", "/a%20b.jpg"},
            {"a+b", "/a%2Bb"},
            {"100%", "/100%25"},
            {"q?x=1", "/q%3Fx%3D1"},
            {"h#1", "/h%231"},
            {"café/ü.jpg", "/caf%C3%A9/%C3%BC.jpg"},
            {"a/b/c", "/a/b/c"}
          ] do
        s3 = s3(&reply(&1, 200))
        assert :ok = S3.put(s3, key, "x"), "put of #{inspect(key)} failed"
        assert_received {:request, request}
        assert request.path == path, "#{inspect(key)} went to #{request.path}"
        assert request.query == ""
      end
    end

    test "keys S3 or a proxy would read differently are refused before any request" do
      for key <- [
            "",
            "/leading",
            "a/../b",
            "./a",
            "a/.",
            <<0xFF, 0xFE>>,
            "a\nb",
            String.duplicate("k", 1025),
            :atom
          ] do
        s3 = s3(&reply(&1, 200))

        for call <- [
              fn -> S3.put(s3, key, "x") end,
              fn -> S3.get(s3, key) end,
              fn -> S3.head(s3, key) end,
              fn -> S3.delete(s3, key) end
            ] do
          assert {:error, %Error{kind: :validation}} = call.()
        end

        refute_received {:request, _}, "sent a request for #{inspect(key)}"
      end
    end

    test "a 1,024-byte key, S3's limit, is accepted" do
      s3 = s3(&reply(&1, 200))
      assert :ok = S3.put(s3, String.duplicate("é", 512), "x")
    end
  end

  describe "get/2" do
    test "returns the object's bytes as stored" do
      s3 = s3(&reply(&1, 200, "jpeg bytes", [{"content-type", "image/jpeg"}]))

      assert {:ok, "jpeg bytes"} = S3.get(s3, "events/1/thumb.jpg")

      assert_received {:request, request}
      assert request.method == "GET"
      assert request.host == "media.t3.storage.dev"
      assert request.path == "/events/1/thumb.jpg"
      assert request.headers["x-amz-content-sha256"] == sha256("")
    end

    test "a JSON or gzip object comes back undecoded" do
      json = ~s({"a":1})
      s3 = s3(&reply(&1, 200, json, [{"content-type", "application/json"}]))
      assert {:ok, ^json} = S3.get(s3, "a.json")

      gz = :zlib.gzip("hello")
      s3 = s3(&reply(&1, 200, gz, [{"content-encoding", "gzip"}]))
      assert {:ok, ^gz} = S3.get(s3, "a.gz")
    end

    test "a missing key is :not_found" do
      s3 = s3(&xml(&1, 404, s3_error("NoSuchKey")))

      assert {:error, %Error{kind: :not_found, status: 404, raw: %{code: "NoSuchKey"}}} =
               S3.get(s3, "events/1/missing.jpg")
    end

    test "NoSuchKey on another status is still :not_found" do
      s3 = s3(&xml(&1, 400, s3_error("NoSuchKey")))
      assert {:error, %Error{kind: :not_found}} = S3.get(s3, "a.jpg")
    end

    test "403 is :forbidden" do
      s3 = s3(&xml(&1, 403, s3_error("AccessDenied")))
      assert {:error, %Error{kind: :forbidden}} = S3.get(s3, "a.jpg")
    end

    test "a transport failure is :transport" do
      s3 = s3(&Req.Test.transport_error(&1, :econnrefused))
      assert {:error, %Error{kind: :transport}} = S3.get(s3, "a.jpg")
    end

    test "a redirect is an error, and the signed request goes to no second host" do
      s3 =
        s3(fn conn ->
          if conn.host == "media.t3.storage.dev" do
            reply(conn, 307, "", [{"location", "https://elsewhere.example/a.jpg"}])
          else
            reply(conn, 200, "stolen")
          end
        end)

      assert {:error, %Error{kind: :provider, status: 307}} = S3.get(s3, "a.jpg")
      assert_received {:request, %{host: "media.t3.storage.dev"}}
      refute_received {:request, _}
    end
  end

  describe "head/2" do
    test "returns the size, etag and content type" do
      s3 =
        s3(
          &reply(&1, 200, "", [
            {"content-length", "5120"},
            {"etag", ~s("9b2cf535f27731c974343645a3985328")},
            {"content-type", "image/jpeg"}
          ])
        )

      assert {:ok,
              %{size: 5120, etag: "9b2cf535f27731c974343645a3985328", content_type: "image/jpeg"}} =
               S3.head(s3, "events/1/thumb.jpg")

      assert_received {:request, %{method: "HEAD", path: "/events/1/thumb.jpg"}}
    end

    test "a missing key is :not_found, though HEAD carries no body" do
      s3 = s3(&reply(&1, 404))
      assert {:error, %Error{kind: :not_found, raw: %{code: nil}}} = S3.head(s3, "gone.jpg")
    end

    test "an answer with no usable size is an error, not a crash" do
      s3 = s3(&reply(&1, 200, "", [{"content-length", "lots"}]))
      assert {:error, %Error{kind: :provider}} = S3.head(s3, "a.jpg")
    end
  end

  describe "delete/2" do
    test "DELETEs the key" do
      s3 = s3(&reply(&1, 204))
      assert :ok = S3.delete(s3, "events/1/thumb.jpg")
      assert_received {:request, %{method: "DELETE", path: "/events/1/thumb.jpg"}}
    end

    test "a missing key answers :ok, as S3 does" do
      s3 = s3(&xml(&1, 404, s3_error("NoSuchKey")))
      assert :ok = S3.delete(s3, "gone.jpg")
    end

    test "a missing bucket is still an error" do
      s3 = s3(&xml(&1, 404, s3_error("NoSuchBucket")))

      assert {:error, %Error{kind: :not_found, raw: %{code: "NoSuchBucket"}}} =
               S3.delete(s3, "a.jpg")
    end

    test "a refused delete is :forbidden" do
      s3 = s3(&xml(&1, 403, s3_error("AccessDenied")))
      assert {:error, %Error{kind: :forbidden}} = S3.delete(s3, "a.jpg")
    end
  end

  defp list_page(keys, prefixes, next_token) do
    contents =
      Enum.map_join(keys, fn key ->
        "<Contents><Key>#{URI.encode_www_form(key) |> String.replace("+", "%20")}</Key>" <>
          "<Size>1</Size></Contents>"
      end)

    common =
      Enum.map_join(prefixes, fn prefix ->
        "<CommonPrefixes><Prefix>#{URI.encode_www_form(prefix)}</Prefix></CommonPrefixes>"
      end)

    truncated =
      if next_token,
        do:
          "<IsTruncated>true</IsTruncated><NextContinuationToken>#{next_token}</NextContinuationToken>",
        else: "<IsTruncated>false</IsTruncated>"

    ~s(<?xml version="1.0" encoding="UTF-8"?>\n) <>
      ~s(<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">) <>
      "<Name>media</Name><EncodingType>url</EncodingType>#{truncated}#{contents}#{common}" <>
      "</ListBucketResult>"
  end

  defp collect_requests(acc \\ []) do
    receive do
      {:request, request} -> collect_requests([request | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "list/2" do
    test "returns the names directly under the folder, sorted, following continuation tokens" do
      s3 =
        s3(fn conn ->
          case URI.decode_query(conn.query_string)["continuation-token"] do
            nil ->
              xml(conn, 200, list_page(["events/1/b.jpg", "events/1/a b.jpg"], [], "tok/1+="))

            "tok/1+=" ->
              xml(conn, 200, list_page(["events/1/clip.mp4"], ["events/1/crops/"], nil))
          end
        end)

      assert {:ok, ["a b.jpg", "b.jpg", "clip.mp4", "crops"]} = S3.list(s3, "events/1")

      assert_received {:request, first}
      assert first.method == "GET"
      assert first.host == "media.t3.storage.dev"
      assert first.path == "/"

      assert query(first) == %{
               "list-type" => "2",
               "prefix" => "events/1/",
               "delimiter" => "/",
               "encoding-type" => "url"
             }

      assert_received {:request, second}
      assert query(second)["continuation-token"] == "tok/1+="
      assert second.query =~ "continuation-token=tok%2F1%2B%3D"
      refute_received {:request, _}
    end

    test "a folder with non-ASCII characters lists its names" do
      s3 = s3(&xml(&1, 200, list_page(["café/ü.jpg", "café/a.jpg"], ["café/sub/"], nil)))
      assert {:ok, ["a.jpg", "sub", "ü.jpg"]} = S3.list(s3, "café")
    end

    test "a page whose keys lie outside the folder is an error" do
      s3 = s3(&xml(&1, 200, list_page(["events/1/a.jpg", "billing/invoice.pdf"], [], nil)))
      assert {:error, %Error{kind: :provider}} = S3.list(s3, "events/1")
    end

    test "a store that sends a fresh token on every page stops at 1,000 pages" do
      s3 =
        s3(fn conn ->
          next = "t#{System.unique_integer([:positive])}"
          xml(conn, 200, list_page([], [], next))
        end)

      assert {:error, %Error{kind: :provider, message: message}} = S3.list(s3, "x")
      assert message =~ "1000 list pages"
      assert length(collect_requests()) == 1000
    end

    test "a prefix with its trailing / lists the same folder" do
      s3 = s3(&xml(&1, 200, list_page(["events/1/a.jpg"], [], nil)))
      assert {:ok, ["a.jpg"]} = S3.list(s3, "events/1/")
      assert_received {:request, %{query: query}}
      assert URI.decode_query(query)["prefix"] == "events/1/"
    end

    test "the folder's own marker object is not a name" do
      s3 = s3(&xml(&1, 200, list_page(["events/1/", "events/1/a.jpg"], [], nil)))
      assert {:ok, ["a.jpg"]} = S3.list(s3, "events/1")
    end

    test "an empty prefix lists the bucket's top level, path-style under /bucket" do
      s3 = s3(&xml(&1, 200, list_page(["top.txt"], ["events/"], nil)), path_style: true)
      assert {:ok, ["events", "top.txt"]} = S3.list(s3, "")
      assert_received {:request, request}
      assert request.path == "/media"
      assert query(request)["prefix"] == ""
    end

    test "a truncated page with no token is an error, not a loop" do
      s3 =
        s3(fn conn ->
          body = list_page(["a"], [], nil) |> String.replace("false", "true")
          xml(conn, 200, body)
        end)

      assert {:error, %Error{kind: :provider}} = S3.list(s3, "x")
      assert_received {:request, _}
      refute_received {:request, _}
    end

    test "a page that repeats its token is an error, not a loop" do
      s3 = s3(&xml(&1, 200, list_page(["x/a"], [], "same")))
      assert {:error, %Error{kind: :provider}} = S3.list(s3, "x")
    end

    test "a body that is not XML is an error" do
      s3 = s3(&reply(&1, 200, "<html>proxy login</html", [{"content-type", "text/html"}]))
      assert {:error, %Error{kind: :provider}} = S3.list(s3, "x")
    end

    test "XML that declares an entity is refused, not expanded" do
      bomb =
        ~s(<?xml version="1.0"?><!DOCTYPE l [<!ENTITY a "aaaaaaaaaa">]>) <>
          "<ListBucketResult><Contents><Key>x/&a;</Key></Contents></ListBucketResult>"

      s3 = s3(&xml(&1, 200, bomb))
      assert {:error, %Error{kind: :provider}} = S3.list(s3, "x")
    end

    test "a refused list is :forbidden" do
      s3 = s3(&xml(&1, 403, s3_error("AccessDenied")))
      assert {:error, %Error{kind: :forbidden}} = S3.list(s3, "x")
    end
  end

  describe "delete_prefix/2" do
    defp keys(n), do: Enum.map(1..n, &"events/1/f#{&1}.jpg")

    defp delete_body_keys(body) do
      Regex.scan(~r{<Key>([^<]*)</Key>}, body) |> Enum.map(fn [_, key] -> key end)
    end

    test "lists every page, then deletes in batches of at most 1,000" do
      all = keys(1001)

      s3 =
        s3(fn conn ->
          case {conn.method, URI.decode_query(conn.query_string)} do
            {"GET", %{"continuation-token" => "p2"}} ->
              xml(conn, 200, list_page(Enum.drop(all, 1000), [], nil))

            {"GET", _} ->
              xml(conn, 200, list_page(Enum.take(all, 1000), [], "p2"))

            {"POST", _} ->
              xml(conn, 200, ~s(<?xml version="1.0"?><DeleteResult></DeleteResult>))
          end
        end)

      assert {:ok, 1001} = S3.delete_prefix(s3, "events/1")

      assert_received {:request, %{method: "GET"} = list}
      assert query(list)["prefix"] == "events/1/"
      refute Map.has_key?(query(list), "delimiter")
      assert_received {:request, %{method: "GET"}}

      assert_received {:request, %{method: "POST"} = first}
      assert_received {:request, %{method: "POST"} = second}
      refute_received {:request, _}

      for post <- [first, second] do
        assert post.path == "/"
        assert post.query == "delete="
        assert post.headers["content-md5"] == Base.encode64(:crypto.hash(:md5, post.body))
        assert post.headers["x-amz-content-sha256"] == sha256(post.body)
        assert post.body =~ "<Quiet>true</Quiet>"
      end

      assert length(delete_body_keys(first.body)) == 1000
      assert delete_body_keys(second.body) == ["events/1/f1001.jpg"]
      assert Enum.sort(delete_body_keys(first.body) ++ ["events/1/f1001.jpg"]) == Enum.sort(all)
    end

    test "a listed key outside the folder deletes nothing" do
      s3 =
        s3(fn conn ->
          case conn.method do
            "GET" -> xml(conn, 200, list_page(["events/1/a.jpg", "billing/invoice.pdf"], [], nil))
            "POST" -> xml(conn, 200, "<DeleteResult/>")
          end
        end)

      assert {:error, %Error{kind: :provider}} = S3.delete_prefix(s3, "events/1")
      assert_received {:request, %{method: "GET"}}
      refute_received {:request, _}
    end

    test "a listed key that decodes to a control character or invalid UTF-8 deletes nothing" do
      for raw <- ["x%2Fa%00b", "x%2F%FF"] do
        page =
          list_page([], [], nil)
          |> String.replace(
            "</ListBucketResult>",
            "<Contents><Key>#{raw}</Key></Contents></ListBucketResult>"
          )

        s3 =
          s3(fn conn ->
            case conn.method do
              "GET" -> xml(conn, 200, page)
              "POST" -> xml(conn, 200, "<DeleteResult/>")
            end
          end)

        assert {:error, %Error{kind: :provider}} = S3.delete_prefix(s3, "x")
        assert_received {:request, %{method: "GET"}}
        refute_received {:request, _}
      end
    end

    test "keys with XML characters are escaped in the delete body" do
      s3 =
        s3(fn conn ->
          case conn.method do
            "GET" -> xml(conn, 200, list_page(["x/a&b<c>.jpg"], [], nil))
            "POST" -> xml(conn, 200, "<DeleteResult/>")
          end
        end)

      assert {:ok, 1} = S3.delete_prefix(s3, "x")
      assert_received {:request, %{method: "GET"}}
      assert_received {:request, %{method: "POST", body: body}}
      assert body =~ "<Key>x/a&amp;b&lt;c&gt;.jpg</Key>"
    end

    test "an empty folder sends no delete" do
      s3 = s3(&xml(&1, 200, list_page([], [], nil)))
      assert {:ok, 0} = S3.delete_prefix(s3, "events/1")
      assert_received {:request, %{method: "GET"}}
      refute_received {:request, _}
    end

    test "per-key errors in the response body are reported" do
      s3 =
        s3(fn conn ->
          case conn.method do
            "GET" ->
              xml(conn, 200, list_page(["x/a", "x/b"], [], nil))

            "POST" ->
              xml(
                conn,
                200,
                "<DeleteResult><Error><Key>x/b</Key><Code>AccessDenied</Code>" <>
                  "<Message>Access Denied</Message></Error></DeleteResult>"
              )
          end
        end)

      assert {:error,
              %Error{kind: :provider, raw: %{errors: [%{key: "x/b", code: "AccessDenied"}]}}} =
               S3.delete_prefix(s3, "x")
    end

    test "a refused batch is an error" do
      s3 =
        s3(fn conn ->
          case conn.method do
            "GET" -> xml(conn, 200, list_page(["x/a"], [], nil))
            "POST" -> xml(conn, 403, s3_error("AccessDenied"))
          end
        end)

      assert {:error, %Error{kind: :forbidden}} = S3.delete_prefix(s3, "x")
    end

    test "an empty or rooted prefix is refused before any request: it would empty the bucket" do
      s3 = s3(&reply(&1, 200))

      for prefix <- ["", "/", "/events", "a/../b"] do
        assert {:error, %Error{kind: :validation}} = S3.delete_prefix(s3, prefix)
      end

      refute_received {:request, _}
    end
  end

  describe "presign/4" do
    # AWS's worked example in "Authenticating Requests: Using Query Parameters
    # (AWS Signature Version 4)", S3 API reference.
    @aws_url "https://examplebucket.s3.amazonaws.com/test.txt" <>
               "?X-Amz-Algorithm=AWS4-HMAC-SHA256" <>
               "&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request" <>
               "&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host" <>
               "&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"

    defp aws_example do
      S3.config!(
        bucket: "examplebucket",
        endpoint: "https://s3.amazonaws.com",
        region: "us-east-1",
        access_key_id: "AKIAIOSFODNN7EXAMPLE",
        secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
      )
    end

    test "signs AWS's documented example to its published URL, byte for byte" do
      assert {:ok, @aws_url} =
               S3.presign(aws_example(), :get, "test.txt",
                 expires_in: 86_400,
                 now: ~U[2013-05-24 00:00:00Z]
               )
    end

    test "a time with microseconds signs as its whole second" do
      assert {:ok, @aws_url} =
               S3.presign(aws_example(), :get, "test.txt",
                 expires_in: 86_400,
                 now: ~U[2013-05-24 00:00:00.999999Z]
               )
    end

    test "PUT differs from GET only in the signature" do
      opts = [expires_in: 3600, now: ~U[2026-10-17 10:00:00Z]]
      {:ok, get} = S3.presign(aws_example(), :get, "a.jpg", opts)
      {:ok, put} = S3.presign(aws_example(), :put, "a.jpg", opts)

      [get_base, get_sig] = String.split(get, "&X-Amz-Signature=")
      [put_base, put_sig] = String.split(put, "&X-Amz-Signature=")
      assert get_base == put_base
      assert get_sig != put_sig
      assert put_sig =~ ~r/\A[0-9a-f]{64}\z/
    end

    test "the URL carries the expiry, the key id and the time, never the secret" do
      {:ok, url} = S3.presign(s3(&reply(&1, 200)), :get, "events/1/a.jpg", expires_in: 900)
      uri = URI.parse(url)

      assert uri.host == "media.t3.storage.dev"
      assert uri.path == "/events/1/a.jpg"

      params = URI.decode_query(uri.query)

      assert Map.keys(params) ==
               ~w(X-Amz-Algorithm X-Amz-Credential X-Amz-Date X-Amz-Expires X-Amz-Signature X-Amz-SignedHeaders)

      assert params["X-Amz-Expires"] == "900"
      assert params["X-Amz-Credential"] =~ ~r"\A#{@key_id}/\d{8}/auto/s3/aws4_request\z"
      refute url =~ @secret
      refute url =~ URI.encode_www_form(@secret)
    end

    test "path style puts the bucket in the path and keeps the port in the host" do
      s3 = s3(&reply(&1, 200), endpoint: "http://minio.local:9000", path_style: true)
      {:ok, url} = S3.presign(s3, :put, "a b.jpg", expires_in: 60)
      uri = URI.parse(url)

      assert {uri.scheme, uri.host, uri.port, uri.path} ==
               {"http", "minio.local", 9000, "/media/a%20b.jpg"}
    end

    test "an endpoint on its own port signs the port into the host, as Req's own signer does" do
      s3 = s3(&reply(&1, 200), endpoint: "http://minio.local:9000", path_style: true)
      now = ~U[2026-10-17 10:00:00Z]

      # Req's internal signer stands in as a second, independent implementation.
      expected =
        Req.Utils.aws_sigv4_url(
          access_key_id: @key_id,
          secret_access_key: @secret,
          region: "auto",
          service: "s3",
          datetime: now,
          method: :put,
          url: "http://minio.local:9000/media/events/a.jpg",
          expires: 60
        )

      assert {:ok, url} = S3.presign(s3, :put, "events/a.jpg", expires_in: 60, now: now)
      assert signature(url) =~ ~r/\A[0-9a-f]{64}\z/
      assert signature(url) == signature(to_string(expected))
    end

    test "every character a key can hold reaches the same key, and adds no query parameter" do
      chars =
        Enum.map(0x20..0x7E, &<<&1>>) ++ ["é", "ü", "日本", "😀", " ", "​"]

      for char <- chars, key = "dir/a#{char}b.jpg", check_key_ok?(key) do
        test = self()

        s3 =
          s3(fn conn ->
            send(test, {:presigned, conn.request_path, conn.query_string})
            reply(conn, 200)
          end)

        assert {:ok, url} = S3.presign(s3, :get, key, expires_in: 60), "refused #{inspect(key)}"

        assert {:ok, %Req.Response{status: 200}} =
                 Req.get(url, plug: s3.req_options[:plug], retry: false)

        assert_received {:presigned, path, query}
        assert URI.decode(path) == "/" <> key, "#{inspect(key)} reached #{path}"
        assert query |> URI.decode_query() |> map_size() == 6, "#{inspect(key)} changed the query"
      end
    end

    test "an expiry outside 1..604800 seconds, or none, is refused" do
      s3 = s3(&reply(&1, 200))

      for opts <- [
            [],
            [expires_in: 0],
            [expires_in: 604_801],
            [expires_in: -1],
            [expires_in: 60.0],
            [expires_in: "60"]
          ] do
        assert {:error,
                %Error{kind: :validation, message: "expires_in must be 1..604800 seconds"}} =
                 S3.presign(s3, :get, "a.jpg", opts),
               "accepted #{inspect(opts)}"
      end

      assert {:ok, _} = S3.presign(s3, :get, "a.jpg", expires_in: 1)
      assert {:ok, _} = S3.presign(s3, :get, "a.jpg", expires_in: 604_800)
    end

    test "a bad method, key, time or option is refused" do
      s3 = s3(&reply(&1, 200))

      for {method, key, opts} <- [
            {:delete, "a.jpg", [expires_in: 60]},
            {"GET", "a.jpg", [expires_in: 60]},
            {:get, "/a.jpg", [expires_in: 60]},
            {:get, "a/../b", [expires_in: 60]},
            {:get, "a.jpg", [expires_in: 60, now: "2026-10-17"]},
            {:get, "a.jpg", [expires_in: 60, content_type: "image/jpeg"]},
            {:get, "a.jpg", :not_a_list}
          ] do
        assert {:error, %Error{kind: :validation}} = S3.presign(s3, method, key, opts),
               "accepted #{inspect({method, key, opts})}"
      end
    end

    test "a presigned pair passes data staging's URL check, special characters included" do
      s3 = s3(&reply(&1, 200))
      {:ok, get} = S3.presign(s3, :get, "datasets/a b[1]{x}.tar.gz", expires_in: 3600)
      {:ok, put} = S3.presign(s3, :put, "artifacts/run 1.tar.gz", expires_in: 3600)

      assert {:ok, %ExAtlas.Spec.Staging{}} =
               ExAtlas.Spec.Staging.new(%{dataset_url: get, artifact_url: put})
    end

    test "a time more than 15 minutes ahead, or outside years 1970 to 9999, is refused" do
      s3 = s3(&reply(&1, 200))
      soon = DateTime.add(DateTime.utc_now(), 10 * 60)

      for now <- [
            DateTime.add(DateTime.utc_now(), 30 * 86_400),
            DateTime.add(DateTime.utc_now(), 20 * 60),
            ~U[1969-12-31 23:59:59Z],
            %{~U[2026-01-01 00:00:00Z] | year: 10_000}
          ] do
        assert {:error, %Error{kind: :validation}} =
                 S3.presign(s3, :get, "a.jpg", expires_in: 60, now: now),
               "accepted now: #{inspect(now)}"
      end

      assert {:ok, _} = S3.presign(s3, :get, "a.jpg", expires_in: 60, now: soon)
    end

    test "a hand-built config with a region that is not a string raises without the key" do
      s3 = %{s3(&reply(&1, 200)) | region: :x}

      error = assert_raise ArgumentError, fn -> S3.presign(s3, :get, "a.jpg", expires_in: 60) end
      refute Exception.message(error) =~ @secret
    end

    test "signs in memory, with no request" do
      assert {:ok, _} = S3.presign(s3(&reply(&1, 200)), :get, "a.jpg", expires_in: 60)
      refute_received {:request, _}
    end
  end

  defp signature(url), do: URI.decode_query(URI.parse(url).query)["X-Amz-Signature"]

  defp check_key_ok?(key), do: String.valid?(key) and not String.match?(key, ~r/[[:cntrl:]]/u)

  describe "no credential leaves in an error" do
    test "neither key appears in any error return, a SignatureDoesNotMatch body included" do
      leaky =
        s3_error(
          "SignatureDoesNotMatch",
          "<AWSAccessKeyId>#{@key_id}</AWSAccessKeyId>" <>
            "<StringToSign>AWS4-HMAC-SHA256 #{@key_id}</StringToSign>" <>
            "<CanonicalRequest>GET / #{@secret}</CanonicalRequest>"
        )

      errors = [
        S3.get(s3(&xml(&1, 403, leaky)), "a.jpg"),
        S3.put(s3(&xml(&1, 403, leaky)), "a.jpg", "x"),
        S3.head(s3(&reply(&1, 403)), "a.jpg"),
        S3.delete(s3(&xml(&1, 400, leaky)), "a.jpg"),
        S3.list(s3(&xml(&1, 403, leaky)), "x"),
        S3.list(s3(&reply(&1, 200, "not xml #{@key_id}")), "x"),
        S3.get(s3(&xml(&1, 403, "<Error><Code>#{@key_id}</Code></Error>")), "a.jpg"),
        S3.get(s3(&xml(&1, 404, s3_error("NoSuchKey"))), "a.jpg"),
        S3.get(s3(&Req.Test.transport_error(&1, :timeout)), "a.jpg"),
        S3.presign(s3(&reply(&1, 200)), :get, "a.jpg", expires_in: 0),
        S3.presign(s3(&reply(&1, 200)), :get, "/a.jpg", expires_in: 60),
        S3.get(s3(&reply(&1, 200)), "/bad"),
        S3.delete_prefix(s3(&reply(&1, 200)), ""),
        S3.delete_prefix(
          s3(fn conn ->
            case conn.method do
              "GET" -> xml(conn, 200, list_page(["x/a"], [], nil))
              "POST" -> xml(conn, 403, leaky)
            end
          end),
          "x"
        )
      ]

      for result <- errors do
        assert {:error, %Error{} = error} = result

        for printed <- [inspect(error), inspect(error, structs: false), Exception.message(error)] do
          refute printed =~ @key_id
          refute printed =~ @secret
        end
      end
    end

    test "the error keeps S3's code and request id, and drops the rest of the body" do
      s3 = s3(&xml(&1, 403, s3_error("SignatureDoesNotMatch", "<StringToSign>x</StringToSign>")))

      assert {:error, %Error{raw: raw, message: message}} = S3.get(s3, "a.jpg")
      assert raw == %{code: "SignatureDoesNotMatch", request_id: "REQ-1"}
      assert message =~ "SignatureDoesNotMatch"
      refute message =~ "Something about"
    end
  end
end
