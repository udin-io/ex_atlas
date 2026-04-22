defmodule ExAtlas.Providers.MockTest do
  use ExUnit.Case, async: false

  use ExAtlas.Test.ProviderConformance,
    provider: :mock,
    reset: {ExAtlas.Providers.Mock, :reset, []}
end
