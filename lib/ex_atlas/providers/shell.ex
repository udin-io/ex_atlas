defmodule ExAtlas.Providers.Shell do
  @moduledoc false
  # POSIX shell quoting for the scripts a provider hands to a pod or a VM.

  @doc """
  Single-quote `value`. Nothing inside single quotes is shell syntax; an
  embedded `'` closes, escapes and reopens.
  """
  @spec quote_arg(String.t()) :: String.t()
  def quote_arg(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  @doc "Quote each argument of `command` and join them with spaces."
  @spec join([String.t()]) :: String.t()
  def join(command), do: Enum.map_join(command, " ", &quote_arg/1)
end
