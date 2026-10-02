defmodule ExAtlas.Spec.Template do
  @moduledoc """
  Normalized template returned by `ExAtlas.create_template/1`,
  `ExAtlas.get_template/2` and `ExAtlas.list_templates/1`.

  `raw` holds the provider's own body without `env`. `env` holds the
  configured values, and `inspect/1` leaves out `env` and `raw`: template env
  holds secrets.
  """

  @derive {Inspect, except: [:env, :raw]}
  @enforce_keys [:id, :provider]
  defstruct id: nil,
            provider: nil,
            name: nil,
            image: nil,
            ports: [],
            env: %{},
            container_disk_gb: nil,
            volume_gb: nil,
            command: nil,
            serverless: false,
            ssh: nil,
            jupyter: nil,
            raw: %{}

  @type t :: %__MODULE__{
          id: String.t(),
          provider: atom(),
          name: String.t() | nil,
          image: String.t() | nil,
          ports: [{:inet.port_number(), :http | :tcp}],
          env: %{optional(String.t()) => String.t()},
          container_disk_gb: pos_integer() | nil,
          volume_gb: pos_integer() | nil,
          command: [String.t()] | nil,
          serverless: boolean(),
          ssh: boolean() | nil,
          jupyter: boolean() | nil,
          raw: map()
        }
end
