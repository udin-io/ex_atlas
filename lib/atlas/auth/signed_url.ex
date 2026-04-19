defmodule Atlas.Auth.SignedUrl do
  @moduledoc """
  HMAC-signed URLs with expiry, for the cases where a client can't set request
  headers (e.g. `<video src>`, `<img src>`, WebSocket upgrade without a
  subprotocol).

  The approach mirrors S3 presigned URLs: Atlas appends two query parameters —
  `exp` (a Unix timestamp when the URL stops working) and `sig` (the HMAC-SHA256
  of the URL's path + `exp`). The pod-side inference server recomputes the HMAC
  and compares with `Plug.Crypto.secure_compare/2`.

  The signing secret is **not** the bearer token from `Atlas.Auth.Token`. It's a
  longer-lived per-pod (or per-user) secret you generate yourself, pass to the
  pod via an env var, and use to sign URLs on the Phoenix side. Atlas gives you
  both halves — signing and verification — to keep everything symmetric.

  ## Example

      secret = :crypto.strong_rand_bytes(32) |> Base.url_encode64()

      signed =
        Atlas.Auth.SignedUrl.sign(
          "https://abc-8000.proxy.runpod.net/stream/session-42",
          secret: secret,
          expires_in: 3600
        )

      # => "https://abc-8000.proxy.runpod.net/stream/session-42?exp=1747000000&sig=..."

      # In the pod's Plug pipeline:
      :ok = Atlas.Auth.SignedUrl.verify(conn.request_path <> "?" <> conn.query_string,
                                       secret: secret)
  """

  @type url :: String.t()
  @type secret :: String.t() | iodata()

  @doc """
  Sign a URL. Returns the URL with `exp` and `sig` query parameters appended.

  ## Options

    * `:secret` (required) — HMAC signing secret.
    * `:expires_in` — seconds from now until the signature expires (default 3600).
    * `:now` — override the current time (integer Unix seconds; for testing).
  """
  @spec sign(url(), keyword()) :: url()
  def sign(url, opts) when is_binary(url) do
    secret = Keyword.fetch!(opts, :secret)
    expires_in = Keyword.get(opts, :expires_in, 3600)
    now = Keyword.get(opts, :now, System.system_time(:second))
    exp = now + expires_in

    uri = URI.parse(url)
    base_params = uri.query |> (&(&1 || "")).() |> URI.decode_query()
    data = canonical(uri.path, base_params, exp)
    sig = hmac(secret, data)

    final_params =
      base_params
      |> Map.put("exp", Integer.to_string(exp))
      |> Map.put("sig", sig)

    uri |> Map.put(:query, encode_query(final_params)) |> URI.to_string()
  end

  @doc """
  Verify a signed URL.

  Accepts either the full URL or just the path + query string.

  Returns `:ok` if the signature is valid and unexpired, or an error tuple:
  `{:error, :expired | :bad_signature | :malformed}`.
  """
  @spec verify(url(), keyword()) :: :ok | {:error, :expired | :bad_signature | :malformed}
  def verify(url, opts) when is_binary(url) do
    secret = Keyword.fetch!(opts, :secret)
    now = Keyword.get(opts, :now, System.system_time(:second))

    with {:ok, uri, params} <- parse(url),
         {:ok, exp} <- fetch_int(params, "exp"),
         {:ok, sig} <- fetch_string(params, "sig"),
         :ok <- check_expiry(exp, now) do
      base_params = params |> Map.delete("sig") |> Map.delete("exp")
      data = canonical(uri.path, base_params, exp)
      expected = hmac(secret, data)
      if Plug.Crypto.secure_compare(sig, expected), do: :ok, else: {:error, :bad_signature}
    end
  end

  defp hmac(secret, data) do
    :hmac
    |> :crypto.mac(:sha256, secret, data)
    |> Base.url_encode64(padding: false)
  end

  defp canonical(path, base_params, exp) do
    params_with_exp = Map.put(base_params, "exp", Integer.to_string(exp))
    "#{path || "/"}?#{encode_query(params_with_exp)}"
  end

  defp parse(url) do
    uri = URI.parse(url)
    params = URI.decode_query(uri.query || "")

    if uri.path == nil and uri.host == nil and params == %{} do
      {:error, :malformed}
    else
      {:ok, uri, params}
    end
  end

  defp fetch_string(params, key) do
    case Map.fetch(params, key) do
      {:ok, v} when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, :malformed}
    end
  end

  defp fetch_int(params, key) do
    with {:ok, v} <- fetch_string(params, key),
         {int, ""} <- Integer.parse(v) do
      {:ok, int}
    else
      _ -> {:error, :malformed}
    end
  end

  defp check_expiry(exp, now) when exp < now, do: {:error, :expired}
  defp check_expiry(_exp, _now), do: :ok

  defp encode_query(params) do
    params |> Enum.sort_by(&elem(&1, 0)) |> URI.encode_query()
  end
end
