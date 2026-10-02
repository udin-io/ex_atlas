defmodule ExAtlas.Spec.Env do
  @moduledoc false
  # The check for a request's container env. NimbleOptions' own map type puts
  # the whole env in its error, values included, so this one names keys and
  # never holds a value.

  alias ExAtlas.Secret

  @spec validate(term()) :: :ok | {:error, NimbleOptions.ValidationError.t()}
  def validate(env) when is_map(env) and not is_struct(env) do
    case Enum.find(env, fn {name, value} ->
           not (is_binary(name) and is_binary(Secret.reveal(value)))
         end) do
      nil ->
        :ok

      {name, _value} when is_binary(name) ->
        error("the value of #{inspect(name)} is not a string")

      _not_a_string_name ->
        error("every name must be a string")
    end
  end

  def validate(_env), do: error("expected a map")

  defp error(detail) do
    {:error,
     %NimbleOptions.ValidationError{
       key: :env,
       value: nil,
       message:
         "invalid value for :env option: expected a map of string names to string values; " <>
           detail
     }}
  end
end
