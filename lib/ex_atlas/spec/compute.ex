defmodule ExAtlas.Spec.Compute do
  @moduledoc """
  Normalized representation of a running or tracked compute resource.

  `:raw` holds the provider's native response for callers that need access to
  fields ExAtlas doesn't normalize.
  """

  @enforce_keys [:id, :provider, :status]
  defstruct id: nil,
            provider: nil,
            status: :provisioning,
            public_ip: nil,
            ports: [],
            gpu_type: nil,
            gpu_count: 1,
            cost_per_hour: nil,
            region: nil,
            image: nil,
            name: nil,
            auth: nil,
            created_at: nil,
            raw: %{}

  @type status :: :provisioning | :running | :stopped | :terminated | :failed

  @type port_binding :: %{
          internal: pos_integer(),
          external: pos_integer() | nil,
          protocol: :http | :tcp,
          url: String.t() | nil
        }

  @type auth_handle :: %{
          scheme: :bearer | :signed_url,
          token: String.t() | nil,
          header: String.t() | nil,
          hash: String.t() | nil
        }

  @type t :: %__MODULE__{
          id: String.t(),
          provider: atom(),
          status: status(),
          public_ip: String.t() | nil,
          ports: [port_binding()],
          gpu_type: String.t() | nil,
          gpu_count: pos_integer(),
          cost_per_hour: float() | Decimal.t() | nil,
          region: String.t() | nil,
          image: String.t() | nil,
          name: String.t() | nil,
          auth: auth_handle() | nil,
          created_at: DateTime.t() | nil,
          raw: map()
        }
end
