import Config

# ExAtlas is a library: the host application owns the real Logger config.
# This file only declares the structured metadata keys ExAtlas's log calls
# attach, so `mix credo` (which reads the Logger config of its own VM) can
# check them. It is not part of the hex package.
config :logger, :default_formatter,
  metadata: [
    :mode,
    :topic,
    :subscriber,
    :queue_len,
    :threshold,
    :timestamp,
    :reason,
    :app,
    :attempted,
    :fallback,
    :exit_code,
    :output,
    :timeout_ms
  ]
