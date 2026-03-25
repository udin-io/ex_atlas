defmodule Atlas.Providers.Adapters.Fly.CliDetector do
  @moduledoc """
  Detects Fly.io API tokens from local CLI sources.

  Resolution chain:
  1. `FLY_ACCESS_TOKEN` environment variable
  2. `~/.fly/config.yml` config file (or custom path via opts)
  3. Returns `:not_found`
  """

  @default_config_path Path.expand("~/.fly/config.yml")

  @doc """
  Detect a Fly.io token using the default config path (~/.fly/config.yml).
  """
  @spec detect() :: {:ok, String.t()} | :not_found
  def detect, do: detect([])

  @doc """
  Detect a Fly.io token with options.

  ## Options

    * `:config_path` - Path to the Fly CLI config YAML file.
      Defaults to `~/.fly/config.yml`.
  """
  @spec detect(keyword()) :: {:ok, String.t()} | :not_found
  def detect(opts) do
    config_path = Keyword.get(opts, :config_path, @default_config_path)

    with :not_found <- from_env(),
         :not_found <- from_config_file(config_path) do
      :not_found
    end
  end

  defp from_env do
    case System.get_env("FLY_ACCESS_TOKEN") do
      nil -> :not_found
      value -> validate_token(value)
    end
  end

  defp from_config_file(path) do
    with true <- File.exists?(path),
         {:ok, content} <- File.read(path),
         {:ok, parsed} <- parse_yaml(content),
         token when is_binary(token) <- Map.get(parsed, "access_token") do
      validate_token(token)
    else
      _ -> :not_found
    end
  end

  defp parse_yaml(content) do
    YamlElixir.read_from_string(content)
  rescue
    _ -> :error
  end

  defp validate_token(value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      :not_found
    else
      {:ok, trimmed}
    end
  end
end
