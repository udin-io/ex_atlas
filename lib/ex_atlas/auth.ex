defmodule ExAtlas.Auth do
  @moduledoc false
  # The container env and the `Compute.auth` handle for a request's `:auth`
  # scheme. Every provider translator calls this, so all of them mint the same
  # variables.

  alias ExAtlas.Auth.Token

  @spec for_scheme(ExAtlas.Spec.ComputeRequest.auth_scheme()) ::
          {%{String.t() => String.t()}, ExAtlas.Spec.Compute.auth_handle() | nil}
  def for_scheme(:none), do: {%{}, nil}

  def for_scheme(:bearer) do
    mint = Token.mint()
    {mint.env, %{scheme: :bearer, token: mint.token, hash: mint.hash, header: mint.header}}
  end

  def for_scheme(:signed_url) do
    secret = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    {%{"ATLAS_SIGNING_SECRET" => secret},
     %{scheme: :signed_url, token: secret, hash: nil, header: nil}}
  end
end
