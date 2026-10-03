defmodule ExAtlas.ReleasePinsTest do
  use ExUnit.Case, async: true

  @pin_files [
    "README.md",
    "guides/fly.md",
    "guides/getting_started.md",
    "lib/mix/tasks/ex_atlas.install.ex"
  ]

  setup do
    [major, minor | _] = String.split(Mix.Project.config()[:version], ".")
    {:ok, series: "#{major}.#{minor}", version: Mix.Project.config()[:version]}
  end

  test "every install pin names the current version's major and minor", %{series: series} do
    for file <- @pin_files do
      pins =
        Regex.scan(~r/\{:ex_atlas, "~> ([0-9.]+)"\}/, File.read!(file), capture: :all_but_first)

      assert pins != [], "#{file} holds no {:ex_atlas, \"~> x.y\"} pin"

      assert Enum.all?(pins, &(&1 == [series])),
             "#{file} pins #{inspect(pins)}, version is #{series}"
    end
  end

  test "CHANGELOG has a release section for the current version", %{version: version} do
    assert File.read!("CHANGELOG.md") =~ ~r/^## v#{Regex.escape(version)} /m
  end

  test "the upgrading guide has a section for the current version", %{version: version} do
    assert File.read!("guides/upgrading.md") =~ "## Upgrading to #{version}\n"
  end
end
