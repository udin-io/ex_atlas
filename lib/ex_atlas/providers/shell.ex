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
  # `trap … EXIT INT TERM` cleans up when the command fails or a signal kills
  # it, not just on a clean exit. A TERM to this shell alone (`docker stop`)
  # runs the trap only once the command exits; the SIGKILL that follows the
  # stop's grace runs nothing. Measured with curlimages/curl on PR 108.
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

  # Positive classes: an id names one path segment (no `.`, `/`), and a key or
  # token is what the providers and `ExAtlas.Callback` mint. A newline in a key
  # would end the config line below and let the rest of the value set any curl
  # option (`url =`, `variable =`); a review of PR 108 reproduced both.
  @id_chars "A-Za-z0-9_-"
  @token_chars "A-Za-z0-9._-"

  @doc """
  A `curl` DELETE of `url` with the Bearer key held in the environment variable
  `key_var`, bounded to 30 s. `url` reads the resource's id from `id_var`.
  Nothing is sent when the id or the key is not a plain token.
  """
  @spec delete_request(String.t(), String.t(), String.t()) :: String.t()
  def delete_request(url, id_var, key_var) do
    request = "#{bearer_config(key_var)} | curl -sS -m 30 -K - -X DELETE \"#{url}\""
    only_if(id_var, @id_chars, only_if(key_var, @token_chars, request)) <> ";"
  end

  defp only_if(var, chars, command),
    do:
      ~s(case "$#{var}" in ""|*[!#{chars}]*\) echo "atlas: #{var} is not a plain token; ) <>
        ~s(skipped" >&2 ;; *\) #{command} ;; esac)

  # The header goes to curl as a `-K -` config line on stdin, written by the
  # `printf` builtin, so no argv carries the key: every process in the
  # container reads every other's argv in `ps`.
  defp bearer_config(key_var),
    do: ~s(printf 'header = "Authorization: Bearer %s"\\n' "$#{key_var}")

  defp finish_report(nil), do: nil

  # Every value here comes from the container's own environment rather than
  # being interpolated into the script, so a callback URL can never be read as
  # shell syntax.
  defp finish_report(%{}) do
    post =
      bearer_config("ATLAS_CALLBACK_TOKEN") <>
        ~s( | curl -sS -m 10 -K - -X POST ) <>
        ~s(-H "Content-Type: application/json" ) <>
        ~s(-d "{\\"exit_code\\":$atlas_code}" ) <>
        ~s("$ATLAS_CALLBACK_URL/finish" || true)

    only_if("ATLAS_CALLBACK_TOKEN", @token_chars, post) <> ";"
  end
end
