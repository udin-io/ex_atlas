defmodule ExAtlas.Test.CredentialResolver do
  @moduledoc """
  A host resolver for `respawn_credentials:`. Each test picks its answer
  through the tuple's args, which the tracking record keeps:

      respawn_credentials: {ExAtlas.Test.CredentialResolver, :resolve, [script]}

  `script` is one of:

    * `{:return, value}` — returns `value`.
    * `{:report, pid, value}` — sends `{:resolver_called, info}` to `pid`,
      then returns `value`.
    * `{:raise, message}` — raises a `RuntimeError` with `message`.
    * `{:throw, value}` and `{:exit, value}` — throws or exits with `value`.
    * `{:sleep, ms, value}` — answers `value` after `ms`.
    * `{:hang, pid}` — sends `{:resolver_started, self()}` to `pid` and never
      answers.
  """

  def resolve({:return, value}, _info), do: value

  def resolve({:report, pid, value}, info) do
    send(pid, {:resolver_called, info})
    value
  end

  def resolve({:raise, message}, _info), do: raise(message)
  def resolve({:throw, value}, _info), do: throw(value)
  def resolve({:exit, value}, _info), do: exit(value)

  def resolve({:sleep, ms, value}, _info) do
    Process.sleep(ms)
    value
  end

  def resolve({:hang, pid}, _info) do
    send(pid, {:resolver_started, self()})
    Process.sleep(:infinity)
  end
end
