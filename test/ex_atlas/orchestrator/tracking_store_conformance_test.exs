defmodule ExAtlas.Orchestrator.TrackingStoreConformanceTest do
  use ExUnit.Case, async: true

  alias ExAtlas.Orchestrator.TrackingStoreConformance

  # A host `use`s the suite from the hex package, which ships only the
  # directories in `package: [files: ...]`.
  test "compiles from a directory the hex package ships" do
    source = TrackingStoreConformance.module_info(:compile)[:source] |> to_string()
    relative = Path.relative_to(source, File.cwd!())
    shipped = Mix.Project.config()[:package][:files]

    assert relative == "lib/ex_atlas/orchestrator/tracking_store_conformance.ex"
    assert hd(Path.split(relative)) in shipped
  end

  # A host's prod release does not include ExUnit, and a host compiled with
  # `--warnings-as-errors` fails on a call into an application it does not
  # depend on. The ExUnit calls belong inside the `quote` the host's test
  # module expands.
  test "calls no ExUnit module from its own code" do
    {:ok, {_, [imports: imports]}} =
      TrackingStoreConformance |> :code.which() |> :beam_lib.chunks([:imports])

    assert imports != []

    refute Enum.any?(imports, fn {module, _fun, _arity} ->
             module |> Atom.to_string() |> String.starts_with?("Elixir.ExUnit")
           end)
  end
end
