defmodule ExAtlas.Callback.Token do
  @moduledoc """
  The credential a pod presents when it calls back into the orchestrating app.

  A **stateless** signed token: `Plug.Crypto.sign/4` over `%{task_id, kinds}`,
  with the token's own maximum age baked in, verified by
  `Plug.Crypto.verify/4`. Nothing is stored anywhere, so verification is a
  single HMAC over data the token carries itself.

  ## Why not the stored hash `ExAtlas.Auth.Token` uses

  `ExAtlas.Auth.Token` guards the *outbound* direction — a browser calling into
  a pod — where the host already holds a row it can hang a hash off. The
  inbound direction has neither half of that:

    * **There is no id to key the hash by at the time the token is minted.**
      RunPod assigns the pod id in the `POST /pods` *response*, and the token
      has to be in the container env that request carries. Hence the
      `task_id` — 16 random bytes minted before the provider is called, which
      also survives an `on_failure: {:respawn, n}` replacement, where the
      compute id does not.
    * **`ExAtlas.Orchestrator.ComputeRegistry` is per node.** A callback that
      lands on node B for a task tracked on node A would find no hash. A signed
      token verifies on any node, with no table to replicate and no lifecycle
      to leak.

  This is also a *different* credential from `ATLAS_PRESHARED_KEY`. That one is
  handed to a browser in the interactive flow; a browser-held secret must never
  also authorize writing into the orchestrator.

  ## Scope and expiry

  A token names one `task_id` and an explicit list of permitted kinds, and its
  max age is set at mint time to the task's remaining budget plus slack — so
  the credential expires with the work rather than outliving it. `verify/2`
  reports `{:error, :expired}` separately from `{:error, :invalid}` only so the
  library can tell them apart in logs; both are a 401 to the caller.

  ## Replay

  Deliberately not defended against with a nonce store. A replayed `progress`
  is indistinguishable from a retry and is harmless — the convention carries a
  `seq` so subscribers can drop stale ones. A replayed `finish` is idempotent:
  the first report wins, and the tracker has stopped by the time a second could
  land. De-facto revocation comes from the registry lookup in
  `ExAtlas.Callback.ingest/3`: no tracker, `410 Gone`.

  ## Configuration

      config :ex_atlas, :callback, secret: System.fetch_env!("ATLAS_CALLBACK_SECRET")

  Generate one with `:crypto.strong_rand_bytes(32) |> Base.encode64()`. It must
  be at least 32 bytes and identical on every node that can receive a callback
  — that is what makes a load balancer in front of the endpoint work.
  """

  @salt "ex_atlas callback token v1"
  @min_secret_bytes 32

  @kinds [:progress, :log, :finish]

  @task_id_bytes 16

  @type kind :: :progress | :log | :finish
  @type task_id :: String.t()
  @type claims :: %{task_id: task_id(), kinds: [kind()]}

  @doc "Every callback kind the boundary knows about."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  Mint a fresh task id: 16 random bytes, unpadded base64url.

  Minted *before* the provider is called, because the compute id does not exist
  until the provider answers — and because it has to survive a respawn, which
  replaces the compute id.
  """
  @spec new_task_id() :: task_id()
  def new_task_id,
    do: @task_id_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @doc """
  Sign a callback token for `task_id`, permitting exactly `kinds`.

  Options:

    * `:secret` — override the configured signing secret.
    * `:max_age` — seconds the token stays valid. Baked into the token, so
      `verify/2` needs no per-task state to enforce it.
    * `:signed_at` — unix seconds the token claims to have been signed at.
  """
  @spec mint(task_id(), [kind()], keyword()) :: String.t()
  def mint(task_id, kinds, opts \\ []) when is_binary(task_id) and is_list(kinds) do
    secret = secret!(opts)
    sign_opts = Keyword.take(opts, [:max_age, :signed_at])

    Plug.Crypto.sign(secret, @salt, %{task_id: task_id, kinds: kinds}, sign_opts)
  end

  @doc """
  Verify a token presented by a pod.

  Constant-time by construction: `Plug.Crypto.verify/4` compares the MAC with
  `Plug.Crypto.secure_compare/2`, and there is no lookup step to leak, because
  the token carries its own subject.
  """
  @spec verify(String.t() | nil, keyword()) :: {:ok, claims()} | {:error, :invalid | :expired}
  def verify(token, opts \\ [])

  def verify(token, opts) when is_binary(token) do
    case Plug.Crypto.verify(secret!(opts), @salt, token, []) do
      {:ok, %{task_id: task_id, kinds: kinds}} when is_binary(task_id) and is_list(kinds) ->
        {:ok, %{task_id: task_id, kinds: Enum.filter(kinds, &(&1 in @kinds))}}

      {:error, :expired} ->
        {:error, :expired}

      _other ->
        {:error, :invalid}
    end
  end

  def verify(_token, _opts), do: {:error, :invalid}

  @doc "Does this token's scope cover `kind`?"
  @spec permits?(claims(), kind()) :: boolean()
  def permits?(%{kinds: kinds}, kind), do: kind in kinds

  @doc """
  Resolve the signing secret, raising a directive error when it is unusable.

  Raising rather than returning an error is deliberate: a callback endpoint
  that silently rejects every request because nobody set a secret is the worst
  possible failure — the pod looks healthy and the operator learns nothing.
  """
  @spec secret!(keyword()) :: String.t()
  def secret!(opts \\ []) do
    secret = Keyword.get_lazy(opts, :secret, &configured_secret/0)

    cond do
      not is_binary(secret) ->
        raise ArgumentError, """
        no callback secret configured.

            config :ex_atlas, :callback, secret: System.fetch_env!("ATLAS_CALLBACK_SECRET")

        Generate one with `:crypto.strong_rand_bytes(32) |> Base.encode64()`, and use
        the same value on every node that can receive a pod callback.
        """

      byte_size(secret) < @min_secret_bytes ->
        raise ArgumentError,
              "the :ex_atlas callback secret must be at least #{@min_secret_bytes} bytes, " <>
                "got #{byte_size(secret)}"

      true ->
        secret
    end
  end

  defp configured_secret do
    :ex_atlas |> Application.get_env(:callback, []) |> Keyword.get(:secret)
  end
end
