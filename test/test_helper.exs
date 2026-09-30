# `:runpod_live` rents a real Runpod pod: run it with
# `RUNPOD_API_KEY=... mix test --only runpod_live`.
ExUnit.start(exclude: [:runpod_live])
