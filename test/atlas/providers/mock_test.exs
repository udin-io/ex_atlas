defmodule Atlas.Providers.MockTest do
  use ExUnit.Case, async: false

  use Atlas.Test.ProviderConformance,
    provider: :mock,
    reset: {Atlas.Providers.Mock, :reset, []}
end
