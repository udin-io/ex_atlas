defmodule Mix.Tasks.ExAtlas.UpgradeTest do
  # Not async: the direct-run test stops and unloads the :ex_atlas application.
  use ExUnit.Case, async: false

  import Igniter.Test

  defp upgrade(argv \\ [], files \\ %{}) do
    [files: files]
    |> test_project()
    |> Igniter.compose_task("ex_atlas.upgrade", argv)
  end

  defp unloaded(fun) do
    :ok = Application.stop(:ex_atlas)
    :ok = Application.unload(:ex_atlas)

    try do
      fun.()
    after
      Application.ensure_all_started(:ex_atlas)
    end
  end

  describe "direct run with no arguments" do
    test "runs the upgraders without the :ex_atlas application loaded" do
      igniter = unloaded(fn -> upgrade() end)

      assert_has_notice(igniter, &(&1 =~ "ExAtlas 0.2 introduces"))
    end
  end
end
