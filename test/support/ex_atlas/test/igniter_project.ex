defmodule ExAtlas.Test.IgniterProject do
  @moduledoc """
  Runs an Igniter task against `Igniter.Test.test_project/1` from a temp dir.

  Igniter's test mode matches `lib/**/*.{ex,exs}` against each test file's
  absolute path, and GlobEx's `**` skips a dot directory. A checkout under
  `~/.claude_worktrees` finds no module, so the project runs from a temp
  directory with no dot segment in its path (#104).

  `File.cd!/2` changes the working directory of the whole VM, so a test
  module that calls this must be `async: false`.
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

  @doc """
  Files for a project whose `Test.Application` starts `children`, a list of
  module names as source text.

  `:alias` puts an alias line in the application module. `:repos` adds a
  module that uses `Ecto.Repo` for each name it lists.
  """
  @spec app_with_children(String.t() | [String.t()], keyword()) :: map()
  def app_with_children(children, opts \\ []) do
    children = children |> List.wrap() |> Enum.join(", ")

    %{
      "mix.exs" => """
      defmodule Test.MixProject do
        use Mix.Project

        def project do
          [app: :test, version: "0.1.0", elixir: "~> 1.17", deps: deps()]
        end

        def application do
          [mod: {Test.Application, []}, extra_applications: [:logger]]
        end

        defp deps, do: []
      end
      """,
      "lib/test/application.ex" => """
      defmodule Test.Application do
        use Application
        #{Keyword.get(opts, :alias, "")}

        @impl true
        def start(_type, _args) do
          children = [#{children}]

          Supervisor.start_link(children, strategy: :one_for_one, name: Test.Supervisor)
        end
      end
      """
    }
    |> Map.merge(repo_files(Keyword.get(opts, :repos, [])))
  end

  defp repo_files(repos) do
    Map.new(repos, fn repo ->
      path = "lib/" <> Macro.underscore(repo) <> ".ex"

      {path,
       """
       defmodule #{repo} do
         use Ecto.Repo, otp_app: :test, adapter: Ecto.Adapters.Postgres
       end
       """}
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
