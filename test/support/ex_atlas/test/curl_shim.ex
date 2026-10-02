defmodule ExAtlas.Test.CurlShim do
  @moduledoc false
  # Runs a provider's `["sh", "-c", script]` start command for real, with a
  # `curl` shim first on PATH, so each request the trap makes is recorded
  # rather than sent. The shim logs its argv, one line a call, and whatever a
  # `-K -` call reads from stdin as its config.

  @doc """
  Write the shim into `tmp`. It exits with `exit_code`, the way a host that
  is down looks when non-zero. A later `run/3` keeps it.
  """
  def install(tmp, exit_code \\ 0) do
    shim = Path.join(tmp, "curl")

    File.write!(shim, """
    #!/bin/sh
    echo "$@" >> #{Path.join(tmp, "curl.log")}
    case " $* " in *" -K - "*) cat >> #{Path.join(tmp, "curl.config")} ;; esac
    exit #{exit_code}
    """)

    File.chmod!(shim, 0o755)
  end

  @doc """
  Run `cmd` under `sh` with `env`. Returns `{exit_status, argv_log,
  config_log}`, each log `""` when curl never ran.
  """
  def run(["sh", "-c", script], tmp, env) do
    unless File.exists?(Path.join(tmp, "curl")), do: install(tmp)

    {_out, status} =
      System.cmd("sh", ["-c", script],
        stderr_to_stdout: true,
        env: [{"PATH", tmp <> ":" <> System.get_env("PATH", "/usr/bin:/bin")} | env]
      )

    {status, read(tmp, "curl.log"), read(tmp, "curl.config")}
  end

  defp read(tmp, name) do
    case File.read(Path.join(tmp, name)) do
      {:ok, text} -> text
      {:error, :enoent} -> ""
    end
  end
end
