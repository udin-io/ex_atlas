defmodule ExAtlas.Providers.HTTP do
  @moduledoc """
  The `Req` plumbing every REST provider shares: the Bearer credential,
  telemetry, the caller's `req_options`, response normalisation, and the
  retry rule for a request that rents something.
  """

  @doc """
  The `auth` option for `Req.new/1`: a function Req calls in its `auth` step.

  `ctx.api_key` is an `ExAtlas.Secret`, so the raw key sits in no
  `Req.Request` field before the header, which Req's `inspect/1` redacts.
  With no key, raises `ExAtlas.Error` of kind `:unauthorized` whose message
  ends with `hint`.
  """
  @spec bearer(ExAtlas.Provider.ctx(), atom(), String.t()) :: (-> {:bearer, String.t()})
  def bearer(%{api_key: nil}, provider, hint) do
    raise ExAtlas.Error, kind: :unauthorized, provider: provider, message: hint
  end

  def bearer(%{api_key: secret}, _provider, _hint),
    do: fn -> {:bearer, ExAtlas.Secret.reveal(secret)} end

  @doc """
  Emit `prefix ++ [:request]` telemetry for every response, with the status
  and the URL without its query string, which carries request filters.
  """
  @spec attach_telemetry(Req.Request.t(), [atom()], atom()) :: Req.Request.t()
  def attach_telemetry(req, prefix, api) do
    Req.Request.append_response_steps(req, [
      {:atlas_telemetry,
       fn {request, response} ->
         :telemetry.execute(
           prefix ++ [:request],
           %{status: response.status},
           %{api: api, method: request.method, url: telemetry_url(request.url)}
         )

         {request, response}
       end}
    ])
  end

  defp telemetry_url(%URI{} = url), do: URI.to_string(%{url | query: nil})

  @doc """
  Drop the `env` a provider echoes from a resource body: the body's own and
  the one of an embedded `template` (a RunPod endpoint carries its template).

  `env` holds the credentials the caller set. A struct that keeps the body in
  `raw` prints them in a crash report or under `inspect(.., structs: false)`,
  which skip the struct's own `Inspect`. A body that is not a map passes
  through.
  """
  @spec drop_env(term()) :: term()
  def drop_env(%{} = body) do
    case Map.delete(body, "env") do
      %{"template" => %{} = template} = rest ->
        %{rest | "template" => Map.delete(template, "env")}

      rest ->
        rest
    end
  end

  def drop_env(other), do: other

  @doc "Merge the caller's `ctx.req_options` in last, so they win."
  @spec merge_user_options(Req.Request.t(), ExAtlas.Provider.ctx()) :: Req.Request.t()
  def merge_user_options(req, %{req_options: opts}) when is_list(opts) and opts != [] do
    Req.merge(req, ExAtlas.Config.reveal_req_options(opts))
  end

  def merge_user_options(req, _ctx), do: req

  @doc """
  Normalise a Req result into `{:ok, body} | {:error, ExAtlas.Error.t()}`.
  """
  @spec handle_response(
          {:ok, Req.Response.t()} | {:error, term()},
          integer() | Range.t(),
          atom()
        ) :: {:ok, term()} | {:error, ExAtlas.Error.t()}
  def handle_response({:ok, %Req.Response{status: status, body: body}}, expected, provider) do
    if status_in?(status, expected) do
      {:ok, body}
    else
      {:error, ExAtlas.Error.from_response(status, body, provider)}
    end
  end

  # Req's JSON decoder fails with the whole body in `data`, and a body can
  # echo the request. The error keeps neither.
  def handle_response({:error, %Jason.DecodeError{}}, _expected, provider) do
    {:error,
     ExAtlas.Error.new(:provider,
       provider: provider,
       message: "the response body is not valid JSON; ExAtlas withholds it"
     )}
  end

  def handle_response({:error, %{__exception__: true} = exception}, _expected, provider) do
    {:error,
     ExAtlas.Error.new(:transport,
       provider: provider,
       message: Exception.message(exception),
       raw: exception
     )}
  end

  def handle_response({:error, other}, _expected, provider) do
    {:error, ExAtlas.Error.new(:transport, provider: provider, raw: other)}
  end

  @doc """
  The `retry` option for a request that rents something, such as a spawn
  `POST`: retry a 429 only.

  A 5xx or a timeout can arrive after the cloud acted, so a retry there rents
  a second resource that nothing tracks. A 429 means the cloud did nothing.
  Req honours the response's `Retry-After`.
  """
  @spec retry_rate_limited(Req.Request.t(), Req.Response.t() | Exception.t()) :: boolean()
  def retry_rate_limited(_request, %Req.Response{status: 429}), do: true
  def retry_rate_limited(_request, _response_or_exception), do: false

  defp status_in?(status, %Range{} = range), do: status in range
  defp status_in?(status, expected) when is_integer(expected), do: status == expected
end
