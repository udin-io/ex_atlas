defmodule ExAtlas.DocsTest do
  use ExUnit.Case, async: true

  @config Mix.Project.config()
  @docs Keyword.fetch!(@config, :docs)
  @doc_files ["README.md" | Path.wildcard("guides/*.md")] ++ Path.wildcard("lib/mix/tasks/*.ex")

  describe "sidebar groups" do
    test "every public module with docs sits in a group" do
      grouped = grouped_modules()

      missing =
        for mod <- documented_lib_modules(), not grouped_in?(grouped, mod), do: inspect(mod)

      assert missing == []
    end

    test "every module a group names exists" do
      all = documented_lib_modules()

      unknown =
        for {_group, entries} <- @docs[:groups_for_modules],
            mod when is_atom(mod) <- entries,
            mod not in all,
            do: inspect(mod)

      assert unknown == []
    end
  end

  describe "install and upgrade commands" do
    test "every {:ex_atlas, \"~> x.y\"} pin matches the project's major.minor" do
      [major, minor | _] = String.split(@config[:version], ".")
      expected = "~> #{major}.#{minor}"

      pins =
        for file <- @doc_files,
            [_, pin] <- Regex.scan(~r/\{:ex_atlas,\s*"([^"]+)"/, File.read!(file)),
            do: {file, pin}

      assert pins != []
      assert for({file, pin} <- pins, pin != expected, do: {file, pin}) == []
    end

    test "mix deps.update, igniter.install and igniter.upgrade name ex_atlas" do
      wrong =
        for file <- @doc_files,
            [cmd, pkg] <-
              Regex.scan(
                ~r/mix (deps\.update|igniter\.install|igniter\.upgrade) ([a-z_]+)/,
                File.read!(file),
                capture: :all_but_first
              ),
            pkg != "ex_atlas",
            do: {file, cmd, pkg}

      assert wrong == []
    end

    test "hex.pm and hexdocs.pm links never name the package atlas" do
      wrong =
        for file <- @doc_files ++ Path.wildcard("lib/**/*.ex"),
            [url, pkg] <-
              Regex.scan(~r{https://(?:hex\.pm/packages|hexdocs\.pm)/([a-z_]+)}, File.read!(file)),
            pkg == "atlas",
            do: {file, url}

      assert wrong == []
    end
  end

  describe "relative Markdown links" do
    test "each points at a file the hex package ships" do
      shipped = @config[:package][:files]

      broken =
        for file <- ["README.md" | Path.wildcard("guides/*.md")],
            [_, target] <- Regex.scan(~r/\]\(([^)\s]+)\)/, File.read!(file)),
            not String.starts_with?(target, ["http://", "https://", "#", "mailto:"]),
            path =
              target |> String.split("#") |> hd() |> then(&Path.join(Path.dirname(file), &1)),
            not (File.exists?(path) and shipped?(path, shipped)),
            do: {file, target}

      assert broken == []
    end
  end

  describe "extras" do
    test "every docs extra ships in the hex package" do
      shipped = @config[:package][:files]
      assert for(f <- @docs[:extras], not shipped?(f, shipped), do: f) == []
    end
  end

  defp shipped?(path, shipped) do
    path = Path.expand(path)

    Enum.any?(shipped, fn entry ->
      entry = Path.expand(entry)
      path == entry or String.starts_with?(path, entry <> "/")
    end)
  end

  defp grouped_modules, do: Enum.flat_map(@docs[:groups_for_modules], fn {_, e} -> e end)

  defp grouped_in?(entries, mod) do
    Enum.any?(entries, fn
      %Regex{} = re -> Regex.match?(re, inspect(mod))
      entry -> entry == mod
    end)
  end

  # Modules compiled from lib/ whose moduledoc is not `false`; test support
  # modules and hidden modules never reach hexdocs.
  defp documented_lib_modules do
    {:ok, modules} = :application.get_key(:ex_atlas, :modules)

    for mod <- modules,
        Code.ensure_loaded?(mod),
        source = mod.module_info(:compile)[:source],
        source |> to_string() |> Path.relative_to_cwd() |> String.starts_with?("lib/"),
        {:docs_v1, _, _, _, moduledoc, _, _} <- [Code.fetch_docs(mod)],
        moduledoc != :hidden,
        do: mod
  end
end
