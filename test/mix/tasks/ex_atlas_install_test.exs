defmodule Mix.Tasks.ExAtlas.InstallTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  @entry "priv/ex_atlas_fly/*.dets"

  alias ExAtlas.Test.IgniterProject

  defp install(files \\ %{}), do: IgniterProject.run("ex_atlas.install", [], files)

  defp gitignore(igniter) do
    if Rewrite.has_source?(igniter.rewrite, ".gitignore") do
      igniter.rewrite |> Rewrite.source!(".gitignore") |> Rewrite.Source.get(:content)
    end
  end

  describe ".gitignore" do
    test "is created with the DETS entry when the project has none" do
      assert gitignore(install()) =~ @entry
    end

    test "gets a newline before the entry when the file lacks a trailing newline" do
      content = gitignore(install(%{".gitignore" => "/deps"}))

      assert content =~ "/deps\n"
      assert content =~ @entry
    end

    test "stays unchanged when it already names priv/ex_atlas_fly" do
      existing = "/deps\npriv/ex_atlas_fly/\n"

      assert gitignore(install(%{".gitignore" => existing})) == existing
    end
  end
end
