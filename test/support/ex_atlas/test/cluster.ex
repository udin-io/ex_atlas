defmodule ExAtlas.Test.Cluster do
  @moduledoc """
  Starts a real second BEAM node for a test, with OTP's `:peer`.

  `start_peer!/0` makes the test node distributed (starting `epmd` if needed),
  starts a peer on `127.0.0.1` with this node's code path, and points the
  peer's provider at this node's Mock through `ExAtlas.Test.RemoteProvider`.
  Node names carry the OS pid and a unique integer, so two `mix test` runs on
  one machine never collide in `epmd`.

  The peer and the test node's distribution stop when the test exits. Use
  these tests in `async: false` modules only: while a peer runs,
  `Node.list/0` is non-empty for every test on this node.
  """

  import ExUnit.Callbacks

  @doc "Start a connected peer node. Returns `{peer_pid, node}`."
  @spec start_peer!() :: {pid(), node()}
  def start_peer! do
    ensure_distributed!()

    {:ok, peer, node} =
      :peer.start_link(%{
        name: unique_name("peer"),
        host: ~c"127.0.0.1",
        longnames: true,
        args: [~c"-setcookie", Atom.to_charlist(:erlang.get_cookie()) | code_path_args()]
      })

    on_exit(fn -> stop_peer(peer) end)

    {:ok, _apps} = :erpc.call(node, :application, :ensure_all_started, [:elixir])
    {:ok, _apps} = :erpc.call(node, :application, :ensure_all_started, [:logger])
    :ok = :erpc.call(node, Application, :load, [:ex_atlas])
    :ok = :erpc.call(node, Application, :put_env, [:ex_atlas, :remote_provider_node, node()])

    {peer, node}
  end

  @doc "Stop a peer and wait until this node has seen it go."
  @spec stop_peer!(pid(), node()) :: :ok
  def stop_peer!(peer, node) do
    :ok = :net_kernel.monitor_nodes(true)
    stop_peer(peer)

    receive do
      {:nodedown, ^node} -> :ok
    after
      5_000 -> raise "peer #{node} did not go down"
    end

    :ok = :net_kernel.monitor_nodes(false)
  end

  @doc "Merge `values` into the peer's `config :ex_atlas, :orchestrator`."
  @spec put_orchestrator_env(node(), keyword()) :: :ok
  def put_orchestrator_env(node, values) do
    current = :erpc.call(node, Application, :get_env, [:ex_atlas, :orchestrator, []])

    :ok =
      :erpc.call(node, Application, :put_env, [
        :ex_atlas,
        :orchestrator,
        Keyword.merge(current, values)
      ])
  end

  defp stop_peer(peer) do
    if Process.alive?(peer), do: :peer.stop(peer)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp ensure_distributed! do
    unless Node.alive?() do
      {_, 0} = System.cmd("epmd", ["-daemon"])

      {:ok, _} =
        :net_kernel.start(:"#{unique_name("primary")}@127.0.0.1", %{name_domain: :longnames})

      on_exit(fn -> :net_kernel.stop() end)
    end

    :ok
  end

  defp unique_name(role) do
    :"exatlas_#{role}_#{System.pid()}_#{System.unique_integer([:positive])}"
  end

  defp code_path_args do
    Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
  end
end
