defmodule ExAtlas.Providers.RunPod.GraphQL do
  @moduledoc """
  Minimal GraphQL client built on `Req`, used only for the few RunPod
  operations not exposed by the REST API (chiefly `gpuTypes` pricing).

  GraphQL-over-HTTP is just `POST {query, variables} → {data | errors}`, so a
  ~30-line wrapper is preferable to adding a heavier GraphQL client
  dependency (Neuron is stale; AbsintheClient is Absinthe-flavored). See
  `ExAtlas.Providers.RunPod.Client.graphql/1` for the Req factory.
  """

  alias ExAtlas.Providers.RunPod.Client

  @doc """
  Execute a GraphQL query or mutation.

  Returns `{:ok, data}` where `data` is the `"data"` object from the response
  (a plain map keyed by string). Returns `{:error, ExAtlas.Error.t()}` on
  transport errors, HTTP errors, or GraphQL-level `errors`.
  """
  @spec query(ExAtlas.Provider.ctx(), String.t(), map()) ::
          {:ok, map()} | {:error, ExAtlas.Error.t()}
  def query(ctx, query, variables \\ %{}) do
    ctx
    |> Client.graphql()
    |> Req.post(json: %{query: query, variables: variables})
    |> case do
      {:ok, %Req.Response{status: 200, body: %{"errors" => [_ | _] = errors}}} ->
        {:error,
         ExAtlas.Error.new(:provider,
           provider: :runpod,
           status: 200,
           message: graphql_message(errors),
           raw: errors
         )}

      {:ok, %Req.Response{status: 200, body: %{"data" => data}}} ->
        {:ok, data}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, ExAtlas.Error.from_response(status, body, :runpod)}

      {:error, exception} ->
        {:error,
         ExAtlas.Error.new(:transport,
           provider: :runpod,
           message: inspect(exception),
           raw: exception
         )}
    end
  end

  defp graphql_message([%{"message" => m} | _]) when is_binary(m), do: m
  defp graphql_message(errors), do: inspect(errors)
end
