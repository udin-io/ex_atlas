# `:runpod_live` rents a real Runpod pod: run it with
# `RUNPOD_API_KEY=... mix test --only runpod_live`. `:lambda_live` rents a
# Lambda instance: `LAMBDA_LABS_API_KEY=... LAMBDA_SSH_KEY_NAME=... mix test
# --only lambda_live`.
ExUnit.start(exclude: [:runpod_live, :lambda_live])
