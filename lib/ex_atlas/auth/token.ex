defmodule ExAtlas.Auth.Token do
  @moduledoc """
  Bearer-token authentication for the "transient per-user pod" pattern.

  When you spawn a compute resource with `auth: :bearer`, ExAtlas:

    1. Generates a cryptographically-random 256-bit token.
    2. Injects it into the pod as the `ATLAS_PRESHARED_KEY` environment variable
       so the inference server inside the pod can validate incoming requests.
    3. Returns the raw token to the caller **once**, in `compute.auth.token`.
    4. Returns the SHA-256 hash in `compute.auth.hash` so the caller can persist
       it (e.g. in Postgres) to validate future control-plane operations without
       storing the secret in plaintext.

  The raw token is never stored by ExAtlas. Treat it like a password: either hand
  it straight to the user's browser (for short-lived sessions) or persist only
  its hash.

  ## Typical flow

      # Fly.io-hosted Phoenix app
      {:ok, compute} = ExAtlas.spawn_compute(gpu: :h100, auth: :bearer, ports: [{8000, :http}])

      # Render a LiveView with a link the user's browser can open directly:
      assign(socket,
        inference_url: compute.ports |> Enum.at(0) |> Map.get(:url),
        inference_token: compute.auth.token
      )

      # The browser sends `Authorization: Bearer <token>` with every request.
      # The inference server inside the pod compares the header to
      # `System.get_env("ATLAS_PRESHARED_KEY")` using `Plug.Crypto.secure_compare/2`.

  ## Validating tokens on the pod side

      # In your inference server (Elixir)
      preshared = System.fetch_env!("ATLAS_PRESHARED_KEY")

      def authenticated?(conn) do
        with ["Bearer " <> token] <- Plug.Conn.get_req_header(conn, "authorization"),
             true <- Plug.Crypto.secure_compare(token, System.get_env("ATLAS_PRESHARED_KEY")) do
          true
        else
          _ -> false
        end
      end
  """

  @token_bytes 32

  @type token :: String.t()
  @type hash :: String.t()

  @doc """
  Mint a new random token.

  Returns a `%{token, hash, header, env: %{"ATLAS_PRESHARED_KEY" => token}}` map ready
  to be threaded into a spawn request's env block and handed to the caller.
  """
  @spec mint() :: %{
          token: token(),
          hash: hash(),
          header: String.t(),
          env: %{String.t() => String.t()}
        }
  def mint do
    token = @token_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    hash = hash(token)

    %{
      token: token,
      hash: hash,
      header: "Authorization: Bearer #{token}",
      env: %{"ATLAS_PRESHARED_KEY" => token}
    }
  end

  @doc "SHA-256 hash of a token, Base16-lowercase encoded."
  @spec hash(token()) :: hash()
  def hash(token) when is_binary(token) do
    :sha256 |> :crypto.hash(token) |> Base.encode16(case: :lower)
  end

  @doc """
  Constant-time comparison between a candidate token and a known hash.

  Prefer this over `==` when validating tokens submitted by clients — it resists
  timing attacks.
  """
  @spec valid?(token(), hash()) :: boolean()
  def valid?(candidate, expected_hash) when is_binary(candidate) and is_binary(expected_hash) do
    Plug.Crypto.secure_compare(hash(candidate), expected_hash)
  end
end
