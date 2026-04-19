defmodule Atlas.Error do
  @moduledoc """
  Canonical error shapes returned by every `Atlas.Provider` callback.

  Providers translate their native error bodies into one of these tagged tuples
  so callers can pattern-match once and handle errors from any provider.

  ## Shapes

    * `{:error, %Atlas.Error{kind: :unauthorized, ...}}` — bad or missing API key.
    * `{:error, %Atlas.Error{kind: :not_found, ...}}` — resource doesn't exist.
    * `{:error, %Atlas.Error{kind: :rate_limited, ...}}` — provider 429.
    * `{:error, %Atlas.Error{kind: :unsupported, ...}}` — provider lacks this feature.
    * `{:error, %Atlas.Error{kind: :provider, ...}}` — provider-reported domain error.
    * `{:error, %Atlas.Error{kind: :transport, ...}}` — HTTP/socket failure.
    * `{:error, %Atlas.Error{kind: :validation, ...}}` — Atlas-side validation failure.
  """

  @enforce_keys [:kind]
  defexception [:kind, :message, :provider, :status, :raw]

  @type kind ::
          :unauthorized
          | :forbidden
          | :not_found
          | :rate_limited
          | :unsupported
          | :provider
          | :transport
          | :validation
          | :timeout
          | :unknown

  @type t :: %__MODULE__{
          kind: kind(),
          message: String.t() | nil,
          provider: atom() | nil,
          status: integer() | nil,
          raw: term()
        }

  @impl true
  def message(%__MODULE__{kind: kind, provider: p, status: s, message: m}) do
    "[#{p || "atlas"}] #{kind}#{if s, do: " (HTTP #{s})", else: ""}: #{m || "no message"}"
  end

  @doc "Build an `Atlas.Error` from fields."
  @spec new(kind(), keyword()) :: t()
  def new(kind, opts \\ []) do
    %__MODULE__{
      kind: kind,
      message: Keyword.get(opts, :message),
      provider: Keyword.get(opts, :provider),
      status: Keyword.get(opts, :status),
      raw: Keyword.get(opts, :raw)
    }
  end

  @doc """
  Translate an HTTP response (`{status, body}`) into an `Atlas.Error`.

  Used by every REST provider to normalize 4xx/5xx responses.
  """
  @spec from_response(integer(), term(), atom()) :: t()
  def from_response(status, body, provider) do
    kind =
      case status do
        401 -> :unauthorized
        403 -> :forbidden
        404 -> :not_found
        408 -> :timeout
        429 -> :rate_limited
        s when s in 400..499 -> :provider
        s when s in 500..599 -> :provider
        _ -> :unknown
      end

    new(kind, provider: provider, status: status, message: extract_message(body), raw: body)
  end

  defp extract_message(%{"error" => %{"message" => m}}) when is_binary(m), do: m
  defp extract_message(%{"error" => m}) when is_binary(m), do: m
  defp extract_message(%{"message" => m}) when is_binary(m), do: m
  defp extract_message(%{"errors" => [%{"message" => m} | _]}) when is_binary(m), do: m
  defp extract_message(body) when is_binary(body), do: body
  defp extract_message(_), do: nil
end
