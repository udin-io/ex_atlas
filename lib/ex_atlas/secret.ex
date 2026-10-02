defmodule ExAtlas.Secret do
  @moduledoc """
  A credential that prints as `#ExAtlas.Secret<redacted>`.

  The BEAM prints a crashed function's arguments in its stacktrace, outside
  any `format_status/1`. ExAtlas wraps `api_key:` and the `:auth` and
  `:headers` entries of `req_options:` in this struct as soon as it receives
  them, so a crash in a tracker or a provider prints no credential.

      iex> secret = ExAtlas.Secret.wrap("sk-live-123")
      iex> inspect(secret)
      "#ExAtlas.Secret<redacted>"
      iex> ExAtlas.Secret.reveal(secret)
      "sk-live-123"

  Pass `api_key: ExAtlas.Secret.wrap(key)` to keep the key out of your own
  frames as well. A provider calls `reveal/1` where its HTTP client reads the
  value, and nowhere else.

  The struct implements no `String.Chars`, so interpolating it raises instead
  of printing the value. The value sits inside a closure, so a printer that
  skips `Inspect` (`inspect(secret, structs: false)`, or Erlang's `~p` in a
  host that formats OTP reports without Elixir's translator) prints
  `#Function<...>`, never the value. A closure stops working once its module's
  code is purged twice, so the struct does not survive a hot code upgrade of
  `ExAtlas.Secret`; nothing in ExAtlas stores it on disk.
  """

  @enforce_keys [:value]
  defstruct [:value]

  @opaque t :: %__MODULE__{value: (-> term())}

  @doc "Wrap `value`. `nil` and an existing `Secret` come back unchanged."
  @spec wrap(term()) :: t() | nil
  def wrap(nil), do: nil
  def wrap(%__MODULE__{} = secret), do: secret
  def wrap(value), do: %__MODULE__{value: fn -> value end}

  @doc "The wrapped value. Any other term, `nil` included, comes back unchanged."
  @spec reveal(t() | term()) :: term()
  def reveal(%__MODULE__{value: value}), do: value.()
  def reveal(other), do: other

  defimpl Inspect do
    def inspect(_secret, _opts), do: "#ExAtlas.Secret<redacted>"
  end
end
