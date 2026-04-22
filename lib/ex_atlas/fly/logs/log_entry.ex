defmodule ExAtlas.Fly.Logs.LogEntry do
  @moduledoc """
  A single parsed log line from the Fly Machines log API.

  The raw Fly API payload is deeply nested; this struct flattens it into a
  simple shape that's easy to render and filter.
  """

  @type t :: %__MODULE__{
          timestamp: String.t() | nil,
          message: String.t() | nil,
          level: String.t() | nil,
          region: String.t() | nil,
          instance: String.t() | nil,
          app_name: String.t() | nil
        }

  defstruct [:timestamp, :message, :level, :region, :instance, :app_name]

  @doc """
  Builds a `LogEntry` from a decoded Fly log JSON object.

  Expected input shape:

      %{
        "timestamp" => "2024-01-01T00:00:00Z",
        "fly" => %{
          "app" => %{"instance" => "abc123", "name" => "myapp"},
          "region" => "cdg"
        },
        "log" => %{"level" => "info"},
        "message" => "Hello world"
      }
  """
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    fly = Map.get(json, "fly", %{})
    app = get_in(fly, ["app"]) || %{}
    log = Map.get(json, "log", %{})

    %__MODULE__{
      timestamp: Map.get(json, "timestamp"),
      message: Map.get(json, "message"),
      level: Map.get(log, "level"),
      region: Map.get(fly, "region"),
      instance: Map.get(app, "instance"),
      app_name: Map.get(app, "name")
    }
  end
end
