if Code.ensure_loaded?(Plug) do
  defmodule ExAtlas.Callback.Plug do
    @moduledoc """
    The inbound HTTP boundary for pod callbacks: mount it, and running
    containers can report progress, stream logs, and declare their exit code.

    Only compiles when the host has `:plug` in its dependency tree (it is an
    optional dependency, the same arrangement `:phoenix_pubsub` and
    `:phoenix_live_dashboard` already use). Without Plug, the framework-free
    `ExAtlas.Callback` still gives you `verify/1` and `ingest/3` for a
    hand-rolled controller.

    Deliberately **not** a `Phoenix.Router` forward: ExAtlas supports
    non-Phoenix consumers — `ExAtlas.Fly.Dispatcher` exists for exactly that
    reason — and a router would force Phoenix on all of them.

    ## Mounting

        # lib/my_app_web/router.ex
        scope "/atlas" do
          forward "/cb", ExAtlas.Callback.Plug
        end

    Three constraints, and getting any of them wrong is the difference between
    a working callback and a security hole:

      * **Outside the `:browser` pipeline.** A pod has no session and no CSRF
        token, and it must not be handed one.
      * **Outside your own authentication plug.** The bearer token in the
        request *is* the authentication; running it through a plug that expects
        a logged-in user only produces confusing 302s.
      * **Not through `Plug.Parsers`.** Its 8 MB default is the memory vector
        this whole module exists to close. This plug reads the body itself,
        with a per-kind cap applied *before* anything is decoded. A `forward`
        in a Phoenix router runs after the endpoint's parsers, so put the
        forward in a scope whose pipeline does not include them — or mount it
        in your endpoint ahead of `Plug.Parsers`:

            plug :atlas_callback

            defp atlas_callback(%{path_info: ["atlas", "cb" | rest]} = conn, _opts) do
              ExAtlas.Callback.Plug.call(%{conn | path_info: rest}, [])
            end

            defp atlas_callback(conn, _opts), do: conn

    ## Routes

      * `POST /progress` — 8 KB, broadcasts `{:progress, payload}`
      * `POST /logs` — 64 KB, broadcasts `{:log, payload}`, retained nowhere
      * `POST /finish` — 8 KB, `{"exit_code": n}`, broadcasts `{:task_report, report}`

    Each carries `Authorization: Bearer $ATLAS_CALLBACK_TOKEN`.

    ## Status codes

    | code | meaning |
    |------|---------|
    | 202  | accepted — handed to the tracker |
    | 400  | body was not a JSON object, or a finish carried no usable `exit_code` |
    | 401  | signature bad, token expired, or the token does not cover this kind |
    | 404  | not one of the three paths |
    | 410  | nothing is tracking that task any more |
    | 413  | body over the cap for this kind |
    | 429  | over the rate budget for this task and kind |

    None of them reveals to an unauthenticated caller whether a given task id
    exists: everything unauthenticated is a 401 before any lookup happens.

    ## Order of operations

    Authenticate, then rate-limit, then read the body, then decode, then hand
    off. Each step is cheaper than the one after it, so the work an attacker
    can make the host do is bounded by how far up the chain they can get — and
    an unauthenticated request never causes a body read at all.
    """

    @behaviour Plug

    import Plug.Conn

    alias ExAtlas.Callback
    alias ExAtlas.Callback.Token

    @impl true
    def init(opts), do: opts

    @impl true
    def call(%Plug.Conn{method: "POST"} = conn, _opts) do
      case Callback.kind_from_path(conn.path_info) do
        {:ok, kind} -> dispatch(conn, kind)
        :error -> respond(conn, 404)
      end
    end

    def call(conn, _opts), do: respond(conn, 404)

    # --- pipeline ---

    defp dispatch(conn, kind) do
      with {:ok, claims} <- authenticate(conn, kind),
           :ok <- Callback.take(claims.task_id, kind) do
        read_and_ingest(conn, kind, claims)
      else
        {:error, reason} -> respond(conn, status_for(reason))
      end
    end

    # The cap goes on `read_body/2`, never on a check after the fact: by the
    # time you could measure a decoded body you have already paid for it. The
    # declared `content-length` is not consulted, because a hostile caller
    # writes that header too.
    defp read_and_ingest(conn, kind, claims) do
      limit = Callback.body_limit(kind)

      case read_body(conn, length: limit, read_length: limit) do
        {:ok, body, conn} -> ingest(conn, kind, claims, body)
        {:more, _partial, conn} -> respond(conn, 413)
        {:error, _reason} -> respond(conn, 400)
      end
    end

    defp ingest(conn, kind, claims, body) do
      with {:ok, payload} <- decode(body),
           :ok <- Callback.ingest(claims.task_id, kind, payload) do
        respond(conn, 202)
      else
        {:error, reason} -> respond(conn, status_for(reason))
      end
    end

    # --- authentication ---

    defp authenticate(conn, kind) do
      with {:ok, token} <- bearer(conn),
           {:ok, claims} <- Callback.verify(token) do
        if Token.permits?(claims, kind), do: {:ok, claims}, else: {:error, :invalid}
      end
    end

    defp bearer(conn) do
      case get_req_header(conn, "authorization") do
        ["Bearer " <> token] -> {:ok, token}
        ["bearer " <> token] -> {:ok, token}
        _other -> {:error, :invalid}
      end
    end

    defp decode(body) do
      case Jason.decode(body) do
        {:ok, payload} -> {:ok, payload}
        {:error, _reason} -> {:error, :malformed_json}
      end
    end

    # --- responses ---

    defp status_for(:invalid), do: 401
    defp status_for(:expired), do: 401
    defp status_for(:not_tracked), do: 410
    defp status_for(:rate_limited), do: 429
    defp status_for(:invalid_payload), do: 400
    defp status_for(:malformed_json), do: 400

    # Empty bodies throughout: there is nothing a pod can do with a message,
    # and an endpoint that echoes anything back is an endpoint that can be
    # made to echo the token.
    defp respond(conn, 429) do
      conn |> put_resp_header("retry-after", "1") |> send_resp(429, "") |> halt()
    end

    defp respond(conn, status), do: conn |> send_resp(status, "") |> halt()
  end
end
