defmodule ExAtlas.DocsTest do
  use ExUnit.Case, async: true

  @config Mix.Project.config()
  @docs Keyword.fetch!(@config, :docs)

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
