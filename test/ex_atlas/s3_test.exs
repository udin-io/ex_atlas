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

  describe "get_range/3" do
    test "sends one Range and answers with the bytes, the range and the total" do
      s3 =
        s3(fn conn ->
          reply(conn, 206, "0123456789", [{"content-range", "bytes 100-109/209715200"}])
        end)

      assert {:ok, %{body: "0123456789", range: 100..109, total: 209_715_200}} =
               S3.get_range(s3, "clips/42.mp4", 100..109)

      assert_received {:request, request}
      assert request.method == "GET"
      assert request.path == "/clips/42.mp4"
      assert request.headers["range"] == "bytes=100-109"
    end

    test "{:from, first} reads to the end of the object" do
      s3 = s3(&reply(&1, 206, "6789", [{"content-range", "bytes 6-9/10"}]))

      assert {:ok, %{body: "6789", range: 6..9, total: 10}} =
               S3.get_range(s3, "a.bin", {:from, 6})

      assert_received {:request, %{headers: %{"range" => "bytes=6-"}}}
    end

    test "a range past the end of a short object comes back cut to the object" do
      s3 = s3(&reply(&1, 206, "89", [{"content-range", "bytes 8-9/10"}]))

      assert {:ok, %{body: "89", range: 8..9, total: 10}} = S3.get_range(s3, "a.bin", 8..99)
    end

    test "a range that starts past the end is :validation, from S3's 416" do
      s3 =
        s3(fn conn ->
          conn
          |> Plug.Conn.put_resp_header("content-range", "bytes */10")
          |> xml(416, s3_error("InvalidRange"))
        end)

      assert {:error, %Error{kind: :validation, status: 416, raw: %{code: "InvalidRange"}}} =
               S3.get_range(s3, "a.bin", 10..19)
    end

    test "a missing key is :not_found" do
      s3 = s3(&xml(&1, 404, s3_error("NoSuchKey")))
      assert {:error, %Error{kind: :not_found}} = S3.get_range(s3, "a.bin", 0..9)
    end

    test "a store that ignores the Range header is an error, not the whole object" do
      s3 = s3(&reply(&1, 200, String.duplicate("x", 100_000)))

      assert {:error, %Error{kind: :provider, message: message}} =
               S3.get_range(s3, "a.bin", 0..9)

      assert message =~ "Range"
    end

    test "a store that answers a range from 0 with the whole, smaller object is read as that range" do
      s3 = s3(&reply(&1, 200, String.duplicate("x", 500)))

      assert {:ok, %{body: body, range: 0..499, total: 500}} = S3.get_range(s3, "a.bin", 0..999)
      assert byte_size(body) == 500

      assert {:ok, %{range: 0..499, total: 500}} = S3.get_range(s3, "a.bin", {:from, 0})
    end

    test "a store that ignores a range from past 0 is an error" do
      s3 = s3(&reply(&1, 200, "0123456789"))
      assert {:error, %Error{kind: :provider}} = S3.get_range(s3, "a.bin", {:from, 6})
      assert {:error, %Error{kind: :provider}} = S3.get_range(s3, "a.bin", 6..9)
    end

    test "a Content-Range other than the one asked for is an error" do
      for {asked, header, body} <- [
            {0..9, "bytes 5-9/10", "56789"},
            {0..9, "bytes 0-9/*", "0123456789"},
            {0..9, "bytes 0-19/20", String.duplicate("x", 20)},
            {0..9, "bytes 0-9/10", "short"},
            {0..9, nil, "0123456789"}
          ] do
        headers = if header, do: [{"content-range", header}], else: []
        s3 = s3(&reply(&1, 206, body, headers))

        assert {:error, %Error{kind: :provider}} = S3.get_range(s3, "a.bin", asked),
               "accepted #{inspect(header)} with #{byte_size(body)} bytes"
      end
    end

    test "ranges S3 cannot serve are refused before any request" do
      s3 = s3(&reply(&1, 206, "x"))

      for range <- [5..4//-1, 0..9//2, -1..3, {:from, -1}, {:to, 3}, :all, "0-9"] do
        assert {:error, %Error{kind: :validation}} = S3.get_range(s3, "a.bin", range),
               "accepted #{inspect(range)}"
      end

      assert {:error, %Error{kind: :validation}} = S3.get_range(s3, "/bad", 0..1)
      refute_received {:request, _}
    end
  end

  describe "download/3" do
    @describetag :tmp_dir

    test "streams the object to a file", %{tmp_dir: dir} do
      chunks = ["first chunk, ", "second chunk, ", "last"]

      s3 =
        s3(fn conn ->
          Enum.reduce(chunks, Plug.Conn.send_chunked(conn, 200), fn chunk, conn ->
            {:ok, conn} = Plug.Conn.chunk(conn, chunk)
            conn
          end)
        end)

      path = Path.join(dir, "42.mp4")
      assert :ok = S3.download(s3, "clips/42.mp4", path)

      assert File.read!(path) == Enum.join(chunks)
      assert File.ls!(dir) == ["42.mp4"]
      assert_received {:request, %{method: "GET", path: "/clips/42.mp4"}}
    end

    test "replaces a file already at the path", %{tmp_dir: dir} do
      path = Path.join(dir, "a.bin")
      File.write!(path, "old and longer contents")

      assert :ok = S3.download(s3(&reply(&1, 200, "new")), "a.bin", path)
      assert File.read!(path) == "new"
    end

    test "hands each chunk to a function, in order" do
      s3 =
        s3(fn conn ->
          Enum.reduce(["a", "b", "c"], Plug.Conn.send_chunked(conn, 200), fn chunk, conn ->
            {:ok, conn} = Plug.Conn.chunk(conn, chunk)
            conn
          end)
        end)

      test = self()
      assert :ok = S3.download(s3, "a.bin", &send(test, {:chunk, &1}))

      assert_received {:chunk, "a"}
      assert_received {:chunk, "b"}
      assert_received {:chunk, "c"}
    end

    test "a missing key writes no file and hands nothing to the function", %{tmp_dir: dir} do
      s3 = s3(&xml(&1, 404, s3_error("NoSuchKey")))
      path = Path.join(dir, "a.bin")

      assert {:error, %Error{kind: :not_found, raw: %{code: "NoSuchKey"}}} =
               S3.download(s3, "a.bin", path)

      assert File.ls!(dir) == []

      test = self()

      assert {:error, %Error{kind: :not_found}} =
               S3.download(s3, "a.bin", &send(test, {:chunk, &1}))

      refute_received {:chunk, _}
    end

    test "a failed download leaves an existing file as it was", %{tmp_dir: dir} do
      path = Path.join(dir, "a.bin")
      File.write!(path, "keep me")

      assert {:error, %Error{kind: :forbidden}} =
               S3.download(s3(&xml(&1, 403, s3_error("AccessDenied"))), "a.bin", path)

      assert File.read!(path) == "keep me"
      assert File.ls!(dir) == ["a.bin"]
    end

    test "a connection that drops partway leaves no file", %{tmp_dir: dir} do
      {port, server} = drop_after(10, 100)

      s3 =
        S3.config!(
          bucket: "media",
          endpoint: "http://127.0.0.1:#{port}",
          path_style: true,
          region: "auto",
          access_key_id: @key_id,
          secret_access_key: @secret,
          req_options: [retry: false, receive_timeout: 5_000]
        )

      path = Path.join(dir, "a.bin")
      assert {:error, %Error{kind: :transport}} = S3.download(s3, "a.bin", path)
      assert_receive {:served, ^server}, 5_000
      assert File.ls!(dir) == []
    end

    test "a download is never retried, so no chunk arrives twice" do
      test = self()

      s3 =
        s3(&reply(&1, 503),
          req_options: [plug: stub(&reply(&1, 503)), retry: :transient, retry_delay: 0]
        )

      assert {:error, %Error{status: 503}} = S3.download(s3, "a.bin", &send(test, {:chunk, &1}))
      assert_received {:request, _}
      refute_received {:request, _}
    end

    test "a target that is neither a path nor a 1-arity function is refused before any request" do
      s3 = s3(&reply(&1, 200, "x"))

      for target <- [:file, fn _a, _b -> :ok end, ~c"charlist/path", ""] do
        assert {:error, %Error{kind: :validation}} = S3.download(s3, "a.bin", target)
      end

      refute_received {:request, _}
    end

    test "a path in a missing folder, or a folder itself, is refused before any request", %{
      tmp_dir: dir
    } do
      s3 = s3(&reply(&1, 200, "x"))

      assert {:error, %Error{kind: :validation}} =
               S3.download(s3, "a.bin", Path.join([dir, "missing", "a.bin"]))

      assert {:error, %Error{kind: :validation}} = S3.download(s3, "a.bin", dir)
      refute_received {:request, _}
    end
  end

  # A server that answers with `sent` of `declared` body bytes, then closes the
  # connection: a download cut off partway.
  defp drop_after(sent, declared) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    test = self()

    server =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\ncontent-length: #{declared}\r\n\r\n" <>
              String.duplicate("x", sent)
          )

        :gen_tcp.close(socket)
        :gen_tcp.close(listen)
        send(test, {:served, self()})
      end)

    {port, server}
  end

  describe "upload_file/4" do
    @describetag :tmp_dir

    @mib 1024 * 1024
    @upload_id "VXBsb2FkIElE+/="

    # A store that takes a multipart upload. `fail_part` answers that part
    # number with a 500; `complete` answers CompleteMultipartUpload.
    defp multipart_store(opts \\ []) do
      fail_part = Keyword.get(opts, :fail_part)

      complete =
        Keyword.get(
          opts,
          :complete,
          &xml(
            &1,
            200,
            ~s(<CompleteMultipartUploadResult><ETag>"x-3"</ETag></CompleteMultipartUploadResult>)
          )
        )

      s3(fn conn ->
        params = URI.decode_query(conn.query_string)

        case {conn.method, params} do
          {"POST", %{"uploads" => ""}} ->
            xml(
              conn,
              200,
              "<InitiateMultipartUploadResult><Bucket>media</Bucket><Key>k</Key>" <>
                "<UploadId>#{@upload_id}</UploadId></InitiateMultipartUploadResult>"
            )

          {"PUT", %{"partNumber" => n, "uploadId" => @upload_id}} ->
            part_reply(conn, n, fail_part)

          {"POST", %{"uploadId" => @upload_id}} ->
            complete.(conn)

          {"DELETE", %{"uploadId" => @upload_id}} ->
            reply(conn, 204)
        end
      end)
    end

    defp part_reply(conn, number, fail_part) do
      if number == to_string(fail_part),
        do: xml(conn, 500, s3_error("InternalError")),
        else: reply(conn, 200, "", [{"etag", ~s("etag-#{number}")}])
    end

    defp file_of(dir, size) do
      path = Path.join(dir, "clip.mp4")
      # Bytes that differ by position, so a part sent from the wrong offset shows.
      File.write!(path, for(i <- 0..(size - 1), into: <<>>, do: <<rem(i, 251)>>))
      path
    end

    test "a file of 2.5 parts goes up in three parts, then one Complete with the ETags in order",
         %{tmp_dir: dir} do
      path = file_of(dir, 5 * @mib * 2 + div(5 * @mib, 2))
      content = File.read!(path)

      assert :ok =
               S3.upload_file(multipart_store(), "clips/42.mp4", path,
                 part_size: 5 * @mib,
                 content_type: "video/mp4"
               )

      requests = collect_requests()

      assert Enum.map(requests, &{&1.method, query(&1)}) == [
               {"POST", %{"uploads" => ""}},
               {"PUT", %{"partNumber" => "1", "uploadId" => @upload_id}},
               {"PUT", %{"partNumber" => "2", "uploadId" => @upload_id}},
               {"PUT", %{"partNumber" => "3", "uploadId" => @upload_id}},
               {"POST", %{"uploadId" => @upload_id}}
             ]

      assert Enum.all?(requests, &(&1.path == "/clips/42.mp4"))
      [create, p1, p2, p3, complete] = requests
      assert create.headers["content-type"] == "video/mp4"
      assert p1.body <> p2.body <> p3.body == content
      assert byte_size(p1.body) == 5 * @mib
      assert byte_size(p2.body) == 5 * @mib
      assert p1.headers["x-amz-content-sha256"] == sha256(p1.body)

      assert complete.body ==
               ~s(<?xml version="1.0" encoding="UTF-8"?>) <>
                 ~s(<CompleteMultipartUpload xmlns="http://s3.amazonaws.com/doc/2006-03-01/">) <>
                 ~s(<Part><PartNumber>1</PartNumber><ETag>&quot;etag-1&quot;</ETag></Part>) <>
                 ~s(<Part><PartNumber>2</PartNumber><ETag>&quot;etag-2&quot;</ETag></Part>) <>
                 ~s(<Part><PartNumber>3</PartNumber><ETag>&quot;etag-3&quot;</ETag></Part>) <>
                 "</CompleteMultipartUpload>"
    end

    test "a failed second part aborts the upload and sends no Complete", %{tmp_dir: dir} do
      path = file_of(dir, 5 * @mib * 2 + 10)

      assert {:error, %Error{kind: :provider, status: 500, raw: %{code: "InternalError"}}} =
               S3.upload_file(multipart_store(fail_part: 2), "clips/42.mp4", path,
                 part_size: 5 * @mib
               )

      assert Enum.map(collect_requests(), &{&1.method, query(&1)["partNumber"]}) == [
               {"POST", nil},
               {"PUT", "1"},
               {"PUT", "2"},
               {"DELETE", nil}
             ]
    end

    test "an Error inside Complete's 200 aborts the upload and returns it", %{tmp_dir: dir} do
      path = file_of(dir, 5 * @mib + 1)
      store = multipart_store(complete: &xml(&1, 200, s3_error("InternalError")))

      assert {:error, %Error{raw: %{code: "InternalError"}}} =
               S3.upload_file(store, "clips/42.mp4", path, part_size: 5 * @mib)

      assert List.last(collect_requests()).method == "DELETE"
    end

    test "a refused Complete aborts the upload", %{tmp_dir: dir} do
      path = file_of(dir, 5 * @mib + 1)
      store = multipart_store(complete: &xml(&1, 400, s3_error("InvalidPart")))

      assert {:error, %Error{kind: :provider, raw: %{code: "InvalidPart"}}} =
               S3.upload_file(store, "clips/42.mp4", path, part_size: 5 * @mib)

      assert List.last(collect_requests()).method == "DELETE"
    end

    test "a part answered without an ETag aborts the upload", %{tmp_dir: dir} do
      path = file_of(dir, 5 * @mib + 1)

      s3 =
        s3(fn conn ->
          case {conn.method, URI.decode_query(conn.query_string)} do
            {"POST", %{"uploads" => ""}} ->
              xml(
                conn,
                200,
                "<InitiateMultipartUploadResult><UploadId>u1</UploadId></InitiateMultipartUploadResult>"
              )

            {"PUT", _} ->
              reply(conn, 200)

            {"DELETE", %{"uploadId" => "u1"}} ->
              reply(conn, 204)
          end
        end)

      assert {:error, %Error{kind: :provider}} =
               S3.upload_file(s3, "a.bin", path, part_size: 5 * @mib)

      assert Enum.map(collect_requests(), & &1.method) == ["POST", "PUT", "DELETE"]
    end

    test "a CreateMultipartUpload answer with no upload id is an error, and no part goes up",
         %{tmp_dir: dir} do
      path = file_of(dir, 5 * @mib + 1)
      s3 = s3(&xml(&1, 200, "<InitiateMultipartUploadResult></InitiateMultipartUploadResult>"))

      assert {:error, %Error{kind: :provider}} =
               S3.upload_file(s3, "a.bin", path, part_size: 5 * @mib)

      assert [%{method: "POST"}] = collect_requests()
    end

    test "a file that needs more than 10,000 parts is refused before any request",
         %{tmp_dir: dir} do
      # A sparse file: its size is set without writing the bytes.
      path = Path.join(dir, "huge")
      {:ok, file} = :file.open(path, [:write, :raw])
      {:ok, _} = :file.position(file, 10_000 * 5 * @mib + 1)
      :ok = :file.truncate(file)
      :ok = :file.close(file)

      assert {:error, %Error{kind: :validation, message: message}} =
               S3.upload_file(s3(&reply(&1, 200)), "a.bin", path, part_size: 5 * @mib)

      assert message =~ "10000 parts"
      assert collect_requests() == []
    end

    test "Create and Complete are sent once, whatever :retry the config sets", %{tmp_dir: dir} do
      path = file_of(dir, 5 * @mib + 1)
      transient = [retry: :transient, retry_delay: 0, max_retries: 2]

      create_fails = s3(&reply(&1, 503), req_options: [plug: stub(&reply(&1, 503))] ++ transient)

      assert {:error, %Error{status: 503}} =
               S3.upload_file(create_fails, "a.bin", path, part_size: 5 * @mib)

      assert [%{method: "POST"}] = collect_requests()

      complete_fails =
        multipart_store(complete: &reply(&1, 503))
        |> Map.update!(:req_options, &Keyword.merge(&1, transient))

      assert {:error, %Error{status: 503}} =
               S3.upload_file(complete_fails, "a.bin", path, part_size: 5 * @mib)

      assert Enum.map(collect_requests(), &{&1.method, query(&1)["partNumber"]}) == [
               {"POST", nil},
               {"PUT", "1"},
               {"PUT", "2"},
               {"POST", nil},
               {"DELETE", nil}
             ]
    end

    test "an abort that fails still returns the first error", %{tmp_dir: dir} do
      path = file_of(dir, 5 * @mib + 1)

      s3 =
        s3(fn conn ->
          case {conn.method, conn.query_string} do
            {"POST", "uploads="} ->
              xml(
                conn,
                200,
                "<InitiateMultipartUploadResult><UploadId>u1</UploadId></InitiateMultipartUploadResult>"
              )

            {"PUT", _} ->
              xml(conn, 403, s3_error("AccessDenied"))

            {"DELETE", _} ->
              xml(conn, 500, s3_error("InternalError"))
          end
        end)

      assert {:error, %Error{kind: :forbidden, raw: %{code: "AccessDenied"}}} =
               S3.upload_file(s3, "a.bin", path, part_size: 5 * @mib)
    end

    test "a file at or under the part size goes up in one PutObject", %{tmp_dir: dir} do
      path = file_of(dir, 1000)

      assert :ok =
               S3.upload_file(s3(&reply(&1, 200)), "a.bin", path, content_type: "video/mp4")

      assert [put] = collect_requests()
      assert put.method == "PUT"
      assert put.query == ""
      assert put.body == File.read!(path)
      assert put.headers["content-type"] == "video/mp4"
    end

    test "an empty file goes up in one PutObject", %{tmp_dir: dir} do
      path = Path.join(dir, "empty")
      File.write!(path, "")

      assert :ok = S3.upload_file(s3(&reply(&1, 200)), "a.bin", path)
      assert [%{method: "PUT", body: ""}] = collect_requests()
    end

    test "a part size under S3's 5 MiB minimum or over its 5 GiB maximum is refused",
         %{tmp_dir: dir} do
      path = file_of(dir, 10)
      s3 = s3(&reply(&1, 200))

      for size <- [5 * @mib - 1, 5 * 1024 * @mib + 1, 0, "8MiB"] do
        assert {:error, %Error{kind: :validation}} =
                 S3.upload_file(s3, "a.bin", path, part_size: size),
               "accepted part_size #{inspect(size)}"
      end

      assert :ok = S3.upload_file(s3, "a.bin", path, part_size: 5 * @mib)
    end

    test "a missing file, a folder, a bad key or an unknown option is refused before any request",
         %{tmp_dir: dir} do
      path = file_of(dir, 10)
      s3 = s3(&reply(&1, 200))

      for {key, file, opts} <- [
            {"a.bin", Path.join(dir, "missing"), []},
            {"a.bin", dir, []},
            {"a.bin", :path, []},
            {"/bad", path, []},
            {"a.bin", path, [acl: "public-read"]},
            {"a.bin", path, [content_type: "a\r\nx-amz-acl: public-read"]}
          ] do
        assert {:error, %Error{kind: :validation}} = S3.upload_file(s3, key, file, opts)
      end

      assert collect_requests() == []
    end
  end

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
        S3.get_range(s3(&xml(&1, 403, leaky)), "a.jpg", 0..9),
        S3.get_range(s3(&xml(&1, 416, leaky)), "a.jpg", 0..9),
        S3.download(s3(&xml(&1, 403, leaky)), "a.jpg", fn _chunk -> :ok end),
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

    @tag :tmp_dir
    test "neither key appears in an upload_file error, at any step", %{tmp_dir: dir} do
      leaky =
        s3_error(
          "SignatureDoesNotMatch",
          "<AWSAccessKeyId>#{@key_id}</AWSAccessKeyId><CanonicalRequest>#{@secret}</CanonicalRequest>"
        )

      path = Path.join(dir, "big")
      File.write!(path, :binary.copy("x", 5 * 1024 * 1024 + 1))

      created =
        "<InitiateMultipartUploadResult><UploadId>u1</UploadId></InitiateMultipartUploadResult>"

      stores = [
        s3(&xml(&1, 403, leaky)),
        s3(fn conn ->
          if conn.method == "POST", do: xml(conn, 200, created), else: xml(conn, 403, leaky)
        end),
        s3(fn conn ->
          case conn.method do
            "POST" ->
              if conn.query_string == "uploads=",
                do: xml(conn, 200, created),
                else: xml(conn, 200, leaky)

            "PUT" ->
              reply(conn, 200, "", [{"etag", ~s("e")}])

            "DELETE" ->
              xml(conn, 403, leaky)
          end
        end)
      ]

      for store <- stores do
        assert {:error, %Error{} = error} =
                 S3.upload_file(store, "a.bin", path, part_size: 5 * 1024 * 1024)

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
