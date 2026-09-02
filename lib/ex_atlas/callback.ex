defmodule ExAtlas.Callback do
  @moduledoc """
  The pod→host callback convention: how a running container reports progress,
  streams logs, and declares its exit code back into the orchestrating app.

  This module is the **framework-free core**. It has no `Plug` dependency and
  makes no assumptions about how the request reached you, so a hand-rolled
  controller (or a Bandit plug, or a Cowboy handler) can use it directly:

      def handle(conn) do
        with {:ok, claims} <- ExAtlas.Callback.verify(bearer_token(conn)),
             true <- ExAtlas.Callback.Token.permits?(claims, :progress),
             {:ok, body} <- read_at_most(conn, ExAtlas.Callback.body_limit(:progress)),
             {:ok, json} <- Jason.decode(body),
             :ok <- ExAtlas.Callback.Limiter.take(claims.task_id, :progress),
             :ok <- ExAtlas.Callback.ingest(claims.task_id, :progress, json) do
          send_resp(conn, 202, "")
        end
      end

  Most hosts should mount `ExAtlas.Callback.Plug` instead, which does exactly
  the above with the ordering and the caps already right.

  ## Why the library ships the endpoint rather than only the prose

  The parts a host would hand-roll are the security-critical parts: the
  pre-decode body cap, constant-time verification, the rate limit, and the
  401/410/413/429 split. Shipping only documentation there is how the
  vulnerability gets written.

  ## The three kinds

  | kind        | path        | body cap | broadcast                  | retained |
  |-------------|-------------|----------|----------------------------|----------|
  | `:progress` | `/progress` | 8 KB     | `{:progress, payload}`     | nothing  |
  | `:log`      | `/logs`     | 64 KB    | `{:log, payload}`          | nothing  |
  | `:finish`   | `/finish`   | 8 KB     | `{:task_report, report}`   | one small map |

  **ExAtlas retains zero log bytes.** `/logs` is a bus, not a store — it
  broadcasts and forgets, exactly as `ExAtlas.Fly.Logs.Streamer` already does
  with Fly log entries. There is no ring buffer to size and no back-pressure to
  get wrong, and a host that subscribes to nothing pays nothing. The
  post-mortem full log belongs in object storage.

  `:progress` deliberately does **not** call `ExAtlas.Orchestrator.touch/1`. It
  would let a compromised pod defeat its own idle TTL, and in `mode: :task` —
  the only mode that spawns callbacks by default — there is no idle clock to
  postpone anyway. So the option would carry risk exactly where it carries no
  benefit.

  ## Spawn side

  `prepare/1` is the other half of the boundary: it validates the `:callback`
  option at the `ExAtlas.Orchestrator.spawn/1` seam — *before* the provider is
  asked to rent anything, so a bad URL can never leave a live pod behind a
  validation error — and mints the `task_id` the token will be bound to.
  `env/2` turns that into the three environment variables the container reads.

  ## Untrusted input

  Everything arriving here came off the public internet from a container we do
  not control. Bodies are capped before they are decoded, payload shapes are
  checked rather than assumed, no atom is ever created from client input, and
  `ingest/3` **sends** — it never calls — so a web request can neither block on
  the tracker nor crash when the task is gone.
  """

  alias ExAtlas.Callback.{Limiter, Token}
  alias ExAtlas.Orchestrator.ComputeRegistry

  @body_limits %{progress: 8 * 1024, log: 64 * 1024, finish: 8 * 1024}

  # The largest exit status a POSIX shell can report: 128 + the highest signal.
  @max_exit_code 255

  # How much longer than the task's own deadline the credential stays valid.
  # Enough to cover the finish grace window and a little clock skew, and no
  # more — the token should expire with the work.
  @token_slack_s 300

  @default_max_age_s 24 * 60 * 60

  @type kind :: Token.kind()
  @type payload :: map()
  @type report :: %{exit_code: non_neg_integer()}

  @typedoc """
  The prepared callback descriptor: what `prepare/1` puts in the spawn opts and
  what a provider translator expands into container environment variables.
  """
  @type config :: %{
          url: String.t(),
          task_id: Token.task_id(),
          kinds: [kind()],
          max_age_s: pos_integer()
        }

  @doc "Every callback kind the boundary knows about."
  @spec kinds() :: [kind()]
  defdelegate kinds(), to: Token

  @doc "Maximum request body, in bytes, accepted for `kind`."
  @spec body_limit(kind()) :: pos_integer()
  def body_limit(kind), do: Map.fetch!(@body_limits, kind)

  @doc """
  Map a mounted sub-path onto a callback kind.

  Matches literals only, so no atom is ever created from a client-supplied
  path segment.
  """
  @spec kind_from_path([String.t()]) :: {:ok, kind()} | :error
  def kind_from_path(["progress"]), do: {:ok, :progress}
  def kind_from_path(["logs"]), do: {:ok, :log}
  def kind_from_path(["finish"]), do: {:ok, :finish}
  def kind_from_path(_path), do: :error

  @doc """
  Verify a bearer token presented by a pod.

  A thin pass-through to `ExAtlas.Callback.Token.verify/2` so a hand-rolled
  controller has one obvious function to call. Both error values are a `401` to
  the caller; they are distinguished only so the difference is legible in logs.
  """
  @spec verify(String.t() | nil) :: {:ok, Token.claims()} | {:error, :invalid | :expired}
  defdelegate verify(token), to: Token

  @doc """
  Hand a verified callback to the tracker for `task_id`.

  Returns `{:error, :not_tracked}` when nothing is tracking that task — the
  task ended, the node holding it is not this one, or the id was never real.
  That is a `410 Gone`, and it is also the boundary's de-facto revocation: a
  leaked token stops being useful the moment its tracker stops.

  Uses `send/2`, never `GenServer.call/3`. A web request that blocked on the
  tracker would turn a slow provider poll into an HTTP timeout and would hand
  an untrusted pod a lever on the orchestrator's mailbox.
  """
  @spec ingest(Token.task_id(), kind(), term()) ::
          :ok | {:error, :not_tracked | :invalid_payload}
  def ingest(task_id, kind, payload) when is_binary(task_id) do
    with {:ok, normalized} <- normalize(kind, payload),
         {:ok, pid} <- lookup(task_id) do
      send(pid, {:atlas_callback, kind, normalized})
      :ok
    end
  end

  @doc """
  Spend one unit of `task_id`'s rate budget for `kind`.

  Re-exported so a hand-rolled controller gets the same limiter the shipped
  plug uses rather than inventing its own.
  """
  @spec take(Token.task_id(), kind()) :: :ok | {:error, :rate_limited}
  defdelegate take(task_id, kind), to: Limiter

  # --- spawn side ---

  @doc """
  Resolve and validate the `:callback` spawn option, minting a task id for it.

  Returns the opts unchanged when no callback is configured — the whole feature
  is strictly additive, and a host that configures nothing must lose nothing.

  Called from `ExAtlas.Orchestrator.spawn/1` *before* the provider call, so a
  malformed URL costs nothing. Validating after the resource exists would leak
  a live, billing pod behind a raise.

  Fails loudly on a loopback or private-network URL unless
  `allow_insecure_callback: true`. A callback the pod can never reach is the
  worst outcome available: the task looks healthy and the operator learns
  nothing until the deadline fires an hour later. For local development, point
  `:callback` at a tunnel (cloudflared, ngrok, a Tailscale funnel).
  """
  @spec prepare(keyword()) :: {:ok, keyword()} | {:error, term()}
  def prepare(opts) do
    allow_insecure? = Keyword.get(opts, :allow_insecure_callback, false)

    case Keyword.get_lazy(opts, :callback, &configured_base_url/0) do
      nil ->
        {:ok, opts}

      url when is_binary(url) ->
        with {:ok, url} <- validate_url(url, allow_insecure?) do
          {:ok, Keyword.put(opts, :callback, build(url, opts))}
        end

      %{task_id: _} = already_prepared ->
        {:ok, Keyword.put(opts, :callback, already_prepared)}

      other ->
        {:error, {:invalid_callback, other}}
    end
  end

  @doc """
  Environment variables a container needs to call back.

  Mints the token here, at the last possible moment, so it exists in exactly
  one place — the pod's environment — and never in ExAtlas's own state.
  """
  @spec env(config(), keyword()) :: %{String.t() => String.t()}
  def env(%{url: url, task_id: task_id, kinds: kinds, max_age_s: max_age}, opts \\ []) do
    %{
      "ATLAS_CALLBACK_URL" => url,
      "ATLAS_CALLBACK_TOKEN" => Token.mint(task_id, kinds, [max_age: max_age] ++ opts),
      "ATLAS_TASK_ID" => task_id
    }
  end

  # --- internals ---

  defp build(url, opts) do
    %{
      url: url,
      task_id: Token.new_task_id(),
      kinds: kinds(),
      max_age_s: max_age_s(Keyword.get(opts, :max_runtime_ms, false))
    }
  end

  defp max_age_s(ms) when is_integer(ms) and ms > 0, do: div(ms, 1000) + @token_slack_s
  defp max_age_s(_), do: @default_max_age_s

  defp configured_base_url do
    :ex_atlas |> Application.get_env(:callback, []) |> Keyword.get(:base_url)
  end

  defp lookup(task_id) do
    if Process.whereis(ComputeRegistry) do
      case Registry.lookup(ComputeRegistry, {:callback, task_id}) do
        [{pid, _}] -> {:ok, pid}
        [] -> {:error, :not_tracked}
      end
    else
      {:error, :not_tracked}
    end
  end

  # A progress or log body is whatever the container wants to say, so the only
  # rule is that it is a JSON object — anything else means the pod and the host
  # disagree about the convention, and guessing would be worse than a 400.
  defp normalize(kind, payload) when kind in [:progress, :log] and is_map(payload),
    do: {:ok, payload}

  # A finish report is the one payload ExAtlas reads rather than relays, so it
  # is the one with a shape. Checked, never coerced: a string "0" is a pod
  # that is not speaking the convention, not a zero.
  defp normalize(:finish, %{"exit_code" => code})
       when is_integer(code) and code >= 0 and code <= @max_exit_code,
       do: {:ok, %{exit_code: code}}

  defp normalize(_kind, _payload), do: {:error, :invalid_payload}

  # --- url validation ---

  defp validate_url(url, allow_insecure?) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host} = uri} when is_binary(host) and host != "" ->
        check_reachability(uri, scheme, host, allow_insecure?)

      _ ->
        {:error, {:invalid_callback_url, :not_absolute}}
    end
  end

  defp check_reachability(uri, scheme, host, allow_insecure?) do
    cond do
      allow_insecure? -> {:ok, trim(uri)}
      scheme != "https" -> {:error, {:invalid_callback_url, :not_https}}
      unreachable_host?(host) -> {:error, {:invalid_callback_url, :not_publicly_reachable}}
      true -> {:ok, trim(uri)}
    end
  end

  defp trim(uri), do: uri |> URI.to_string() |> String.trim_trailing("/")

  # No DNS resolution: a lookup at spawn time is a network call on the hot path
  # and answers a different question anyway (what the name resolves to *here*,
  # not from inside the provider's network). This catches the mistake people
  # actually make — pointing a pod at the laptop it was launched from.
  defp unreachable_host?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} -> private_address?(address)
      {:error, :einval} -> private_name?(String.downcase(host))
    end
  end

  defp private_address?({127, _, _, _}), do: true
  defp private_address?({10, _, _, _}), do: true
  defp private_address?({172, b, _, _}) when b >= 16 and b <= 31, do: true
  defp private_address?({192, 168, _, _}), do: true
  defp private_address?({169, 254, _, _}), do: true
  defp private_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp private_address?({a, _, _, _, _, _, _, _}) when a >= 0xFC00 and a <= 0xFDFF, do: true
  defp private_address?(_address), do: false

  defp private_name?("localhost"), do: true

  defp private_name?(host),
    do: String.ends_with?(host, [".localhost", ".local", ".internal", ".home.arpa"])
end
