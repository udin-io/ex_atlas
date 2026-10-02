defmodule ExAtlas.Test.CredentialResolver do
  @moduledoc """
  A host resolver for `respawn_credentials:`. Each test picks its answer
  through the tuple's args, which the tracking record keeps:

      respawn_credentials: {ExAtlas.Test.CredentialResolver, :resolve, [script]}

  The args land in the tracking record, so no script carries a value the
  resolver hands back as a secret; `:fixed` and its kin return values kept in
  this module, from `credentials/0` and `env/0`.

  `script` is one of:

    * `:fixed` — returns `{:ok, s3: credentials() merged with info.s3, env:
      env()}`, as the guide's example resolver does. `:fixed_s3` returns the
      `s3:` alone and `:fixed_env` the `env:` alone. `:broken_secret`
      returns an `env:` whose check raises.
    * `{:return, value}` — returns `value`.
    * `{:merge_s3, credentials, rest}` — returns `{:ok, [s3: s3] ++ rest}`,
      where `s3` is `credentials` merged with `info.s3`, as the guide's
      example resolver does.
    * `{:report, pid, script}` — sends `{:resolver_called, info}` to `pid`,
      then answers as `script` does.
    * `{:raise, message}` — raises a `RuntimeError` with `message`.
    * `{:throw, value}` and `{:exit, value}` — throws or exits with `value`.
    * `{:sleep, ms, value}` — answers `value` after `ms`.
    * `{:hang, pid}` — sends `{:resolver_started, self()}` to `pid` and never
      answers.
  """

  @behaviour ExAtlas.Orchestrator.RespawnCredentials

  @credentials %{access_key_id: "tid-resolved-7a41", secret_access_key: "tsec-resolved-0e58"}
  @env %{"HF_TOKEN" => "hf-resolved-91d2", "WANDB_PROJECT" => "wandb-resolved-5c07"}

  @doc "The `s3:` credentials `:fixed` returns."
  def credentials, do: @credentials

  @doc "The `env:` `:fixed` returns."
  def env, do: @env

  def resolve(:fixed, info), do: {:ok, s3: Map.merge(@credentials, info.s3), env: @env}
  def resolve(:fixed_s3, info), do: {:ok, s3: Map.merge(@credentials, info.s3)}
  def resolve(:fixed_env, _info), do: {:ok, env: @env}

  # A hand-built Secret whose value is no function: revealing it raises
  # `BadFunctionError`, with the term in the message.
  def resolve(:broken_secret, _info),
    do:
      {:ok,
       env: %{"HF_TOKEN" => %ExAtlas.Secret{value: "hf-badfun-leak-3d6a"}, "WANDB_PROJECT" => "w"}}

  def resolve({:return, value}, _info), do: value

  def resolve({:merge_s3, credentials, rest}, info),
    do: {:ok, [s3: Map.merge(credentials, info.s3)] ++ rest}

  def resolve({:report, pid, script}, info) do
    send(pid, {:resolver_called, info})
    resolve(script, info)
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
