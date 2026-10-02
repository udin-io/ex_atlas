defmodule ExAtlas.Error do
  @moduledoc """
  Canonical error shapes returned by every `ExAtlas.Provider` callback.

  Providers translate their native error bodies into one of these tagged tuples
  so callers can pattern-match once and handle errors from any provider.

  ## Shapes

    * `{:error, %ExAtlas.Error{kind: :unauthorized, ...}}` — bad or missing API key.
    * `{:error, %ExAtlas.Error{kind: :not_found, ...}}` — resource doesn't exist.
    * `{:error, %ExAtlas.Error{kind: :rate_limited, ...}}` — provider 429.
    * `{:error, %ExAtlas.Error{kind: :unsupported, ...}}` — provider lacks this feature.
    * `{:error, %ExAtlas.Error{kind: :provider, ...}}` — provider-reported domain error.
    * `{:error, %ExAtlas.Error{kind: :transport, ...}}` — HTTP/socket failure.
    * `{:error, %ExAtlas.Error{kind: :validation, ...}}` — ExAtlas-side validation failure.
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

  @doc "Build an `ExAtlas.Error` from fields."
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
  Translate an HTTP response (`{status, body}`) into an `ExAtlas.Error`.

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

    new(kind,
      provider: provider,
      status: status,
      message: extract_message(body),
      raw: error_raw(status, body)
    )
  end

  # A 2xx the caller did not expect carries the resource, which can hold the
  # credentials the request set (a RunPod pod body echoes its `env`).
  defp error_raw(status, _body) when status in 200..299, do: nil
  defp error_raw(_status, body), do: drop_error_values(body)

  # RFC 9457 problem details (Runpod REST v2): `detail` says what went wrong,
  # `errors` lists each invalid field.
  defp extract_message(%{"detail" => d} = body) when is_binary(d) do
    case body |> Map.get("errors") |> error_texts() do
      [] -> d
      texts -> "#{d} (#{Enum.join(texts, "; ")})"
    end
  end

  defp extract_message(%{"error" => %{"message" => m}}) when is_binary(m), do: m
  defp extract_message(%{"error" => m}) when is_binary(m), do: m
  defp extract_message(%{"message" => m}) when is_binary(m), do: m
  defp extract_message(%{"errors" => [%{"message" => m} | _]}) when is_binary(m), do: m
  defp extract_message(%{"errors" => [m | _]}) when is_binary(m), do: m
  defp extract_message(body) when is_binary(body), do: body
  defp extract_message(_), do: nil

  # An RFC 9457 error object's `value` echoes the rejected input, which can be
  # a secret from the request body; `raw` keeps everything else.
  defp drop_error_values(%{"errors" => errors} = body) when is_list(errors) do
    %{body | "errors" => Enum.map(errors, &drop_value/1)}
  end

  defp drop_error_values(%{errors: errors} = body) when is_list(errors) do
    %{body | errors: Enum.map(errors, &drop_value/1)}
  end

  defp drop_error_values(body), do: body

  defp drop_value(%{} = error), do: Map.drop(error, ["value", :value])
  defp drop_value(error), do: error

  # An error entry may be a string or an object. An object's `value` is the
  # rejected input, which can be a secret from the request, so only its
  # `location` and `message` reach the text.
  defp error_texts(errors) when is_list(errors), do: Enum.flat_map(errors, &error_text/1)
  defp error_texts(_), do: []

  defp error_text(text) when is_binary(text), do: [text]

  defp error_text(%{"message" => m} = e) when is_binary(m) do
    case e["location"] do
      loc when is_binary(loc) -> ["#{loc}: #{m}"]
      _ -> [m]
    end
  end

  defp error_text(_), do: []
end
