defmodule ExAtlas.Providers.LambdaLabsConformanceTest do
  use ExUnit.Case, async: false

  use ExAtlas.Test.ProviderConformance,
    provider: :lambda_labs,
    reset: {ExAtlas.Test.FakeLambda, :start, []}
end
