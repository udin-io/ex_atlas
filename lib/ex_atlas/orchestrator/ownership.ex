defmodule ExAtlas.Orchestrator.Ownership do
  @moduledoc """
  Which node a pod belongs to, read from the pod's name.

  Every node that shares a provider account lists every pod on it, and its
  Registry and tracking store know only the pods that node spawned. So a
  Reaper cannot tell "nobody tracks this pod" from "another node tracks this
  pod". The owner name closes that gap: each node sets its own

      config :ex_atlas, :orchestrator, reap_owner: "m1"

  `ExAtlas.Orchestrator.spawn/1` writes it into the pod name, and the Reaper
  deletes only untracked pods that carry it:

      iex> ExAtlas.Orchestrator.Ownership.classify("atlas-m1-train-42", "atlas-", "m1")
      :ours
      iex> ExAtlas.Orchestrator.Ownership.classify("atlas-m2-train-42", "atlas-", "m1")
      {:other, "m2"}
      iex> ExAtlas.Orchestrator.Ownership.classify("atlas-m1", "atlas-", "m1")
      :unowned
      iex> ExAtlas.Orchestrator.Ownership.classify("atlas-", "atlas-", "m1")
      :unowned
      iex> ExAtlas.Orchestrator.Ownership.classify("atlas-M1-train-42", "atlas-", "m1")
      {:other, "M1"}

  The owner must stay the same across restarts of one node, or the restarted
  node leaves its own crash leftovers to the operator. On Fly that is
  `System.get_env("FLY_MACHINE_ID")`; `node()` is not, because the Phoenix
  Fly template puts the image ref in `RELEASE_NODE`.

  The owner allows `a-z` and `0-9` only. A dash would let owner `m1` match
  the pods of owner `m1-x`.
  """

  alias ExAtlas.Error

  @owner_format ~r/\A[a-z0-9]{1,32}\z/
  @default_prefix "atlas-"

  @doc """
  The configured `:reap_owner`: `{:ok, nil}` when unset, `{:ok, owner}` when
  valid, and a validation error otherwise.
  """
  @spec owner() :: {:ok, String.t() | nil} | {:error, Error.t()}
  def owner do
    :ex_atlas
    |> Application.get_env(:orchestrator, [])
    |> Keyword.get(:reap_owner)
    |> validate()
  end

  defp validate(nil), do: {:ok, nil}

  defp validate(owner) when is_binary(owner) do
    if Regex.match?(@owner_format, owner), do: {:ok, owner}, else: invalid(owner)
  end

  defp validate(owner), do: invalid(owner)

  # The value is not echoed: a mistyped env var can hold a secret.
  defp invalid(owner) do
    {:error,
     Error.new(:validation,
       message:
         "invalid :reap_owner (#{describe(owner)}): use 1 to 32 characters from a-z and 0-9, " <>
           "and keep it the same across restarts of this node"
     )}
  end

  defp describe(owner) when is_binary(owner), do: "a string of #{String.length(owner)} characters"
  defp describe(owner) when is_atom(owner), do: "an atom"
  defp describe(owner) when is_integer(owner), do: "an integer"
  defp describe(_owner), do: "not a string"

  @doc """
  The `:reap_name_prefix` the Reaper matches, `"atlas-"` by default.
  """
  @spec prefix() :: String.t()
  def prefix do
    :ex_atlas
    |> Application.get_env(:orchestrator, [])
    |> Keyword.get(:reap_name_prefix, @default_prefix)
  end

  @doc """
  Rewrite `:name` in spawn opts from `<prefix><rest>` to
  `<prefix><owner>-<rest>`.

  It leaves the name alone when no owner is set, when the name lacks the
  prefix, and when the name already carries this owner, so a respawn or an
  adopted record never stamps twice.
  """
  @spec stamp(keyword()) :: {:ok, keyword()} | {:error, Error.t()}
  def stamp(opts) do
    with {:ok, owner} <- owner() do
      case Keyword.fetch(opts, :name) do
        {:ok, name} -> {:ok, Keyword.put(opts, :name, stamp_name(name, prefix(), owner))}
        :error -> {:ok, opts}
      end
    end
  end

  defp stamp_name(name, _prefix, nil), do: name

  defp stamp_name(name, prefix, owner) when is_binary(name) and is_binary(prefix) do
    stamped = prefix <> owner <> "-"

    cond do
      String.starts_with?(name, stamped) -> name
      String.starts_with?(name, prefix) -> stamped <> String.replace_prefix(name, prefix, "")
      true -> name
    end
  end

  defp stamp_name(name, _prefix, _owner), do: name

  @doc """
  Whose pod `name` is, for a node whose owner is `owner`.

  `:unowned` means the name has no owner segment: no dash after the prefix,
  or nothing before that dash.
  """
  @spec classify(String.t(), String.t(), String.t()) ::
          :ours | {:other, String.t()} | :unowned
  def classify(name, prefix, owner) do
    with true <- String.starts_with?(name, prefix),
         [segment, _rest] <- String.split(String.replace_prefix(name, prefix, ""), "-", parts: 2),
         true <- segment != "" do
      if segment == owner, do: :ours, else: {:other, segment}
    else
      _ -> :unowned
    end
  end
end
