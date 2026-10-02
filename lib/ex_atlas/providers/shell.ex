defmodule ExAtlas.Providers.Shell do
  @moduledoc false
  # POSIX shell for the scripts a provider hands to a pod or a VM: quoting, and
  # the trap that reports a command's exit and deletes the resource after it.

  alias ExAtlas.Spec.ComputeRequest

  @doc """
  Single-quote `value`. Nothing inside single quotes is shell syntax; an
  embedded `'` closes, escapes and reopens.
  """
  @spec quote_arg(String.t()) :: String.t()
  def quote_arg(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  @doc "Quote each argument of `command` and join them with spaces."
  @spec join([String.t()]) :: String.t()
  def join(command), do: Enum.map_join(command, " ", &quote_arg/1)

  @doc """
  The start command for `request` on a provider whose container deletes itself
  with `delete`, a shell line from `delete_request/2`.

  `nil` for no command; the command as is when there is nothing to trap for
  (`self_terminate: false` and no callback); else `["sh", "-c", script]`.
  """
  @spec start_command(ComputeRequest.t(), String.t()) :: [String.t()] | nil
  # An absent and an empty command alike leave the image's own CMD to run.
  # Wrapping an empty command would fire the trap immediately and delete the
  # resource before anything ran, so both mean "leave it unset".
  def start_command(%ComputeRequest{command: nil}, _delete), do: nil
  def start_command(%ComputeRequest{command: []}, _delete), do: nil

  def start_command(%ComputeRequest{command: cmd, self_terminate: false, callback: nil}, _delete),
    do: cmd

  def start_command(%ComputeRequest{command: cmd} = req, delete),
    do: ["sh", "-c", wrapped(req, cmd, delete)]

  # Nothing outside the container learns the command's exit code: RunPod's
  # REST v2 `runtime` carries uptime and utilisation, not container state, and
  # under v1 a pod whose command exited went on reading `RUNNING` and billing.
  #
  # The only party that knows the container ended is the container. RunPod and
  # Vast inject the resource's id and a key scoped to it into every container,
  # so it can delete itself with no secret of ours travelling to it.
  # `trap … EXIT INT TERM` means a crash and a signal clean up too, not just a
  # clean exit.
  #
  # `curl` rather than a provider CLI: curl is in nearly every base image and
  # the CLIs in nearly none. An image with neither wants
  # `self_terminate: false` and the orchestrator's `:max_runtime_ms` backstop.
  #
  # What this cannot cover: SIGKILL, the OOM killer, and a wedged process —
  # nothing runs in the container at all in those cases. That is precisely the
  # set `ExAtlas.Orchestrator.run_task/1`'s deadline exists for, which is why
  # the two mechanisms are both required rather than alternatives.
  # `atlas_code=$?` must be the very first thing in the trap: anything else runs
  # first and clobbers the status we are trying to report.
  #
  # The finish POST goes *before* the DELETE, and swallows its own failure, for
  # two reasons. It has to be a marker written while the resource still exists,
  # so a later disappearance is no longer ambiguous — that is the spot fix. And
  # the DELETE is the line that stops the meter, so an unreachable callback host
  # must never be able to skip it. `-m` bounds the same risk in time.
  defp wrapped(req, command, delete) do
    body =
      [finish_report(req.callback), if(req.self_terminate, do: delete)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    "atlas_self_terminate() { atlas_code=$?; #{body} }; " <>
      "trap atlas_self_terminate EXIT INT TERM; " <> join(command)
  end

  @doc """
  A `curl` DELETE of `url` with the Bearer key held in the environment variable
  `key_var`, bounded to 30 s. `url` may name environment variables (`$ID`).
  """
  @spec delete_request(String.t(), String.t()) :: String.t()
  def delete_request(url, key_var),
    do: "curl -sS -m 30 -X DELETE -H \"Authorization: Bearer $#{key_var}\" \"#{url}\";"

  defp finish_report(nil), do: nil

  # Every value here comes from the container's own environment rather than
  # being interpolated into the script, so a callback URL can never be read as
  # shell syntax.
  defp finish_report(%{}) do
    ~s(curl -sS -m 10 -X POST ) <>
      ~s(-H "Authorization: Bearer $ATLAS_CALLBACK_TOKEN" ) <>
      ~s(-H "Content-Type: application/json" ) <>
      ~s(-d "{\\"exit_code\\":$atlas_code}" ) <>
      ~s("$ATLAS_CALLBACK_URL/finish" || true;)
  end
end
