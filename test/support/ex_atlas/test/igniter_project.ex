defmodule ExAtlas.Test.IgniterProject do
  @moduledoc """
  Runs an Igniter task against `Igniter.Test.test_project/1` from a temp dir.

  Igniter's test mode matches `lib/**/*.{ex,exs}` against each test file's
  absolute path, and GlobEx's `**` skips a dot directory. A checkout under
  `~/.claude_worktrees` finds no module, so the project runs from a temp
  directory with no dot segment in its path (#104).
  """

  @doc "Compose `task` with `argv` over a test project holding `files`."
  @spec run(String.t(), [String.t()], map()) :: Igniter.t()
  def run(task, argv \\ [], files \\ %{}) do
    in_tmp_dir(fn ->
      [files: files]
      |> Igniter.Test.test_project()
      |> Igniter.compose_task(task, argv)
    end)
  end

  @doc "Run `fun` with a fresh temp dir as the working directory."
  @spec in_tmp_dir((-> result)) :: result when result: term()
  def in_tmp_dir(fun) do
    dir = Path.join(System.tmp_dir!(), "ex_atlas_igniter_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      File.cd!(dir, fun)
    after
      File.rm_rf!(dir)
    end
  end
end
