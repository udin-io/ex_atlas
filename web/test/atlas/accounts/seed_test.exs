defmodule Atlas.Accounts.SeedTest do
  use Atlas.DataCase, async: false

  require Ash.Query

  describe "seeds.exs" do
    test "creates admin user with confirmed email" do
      Code.eval_file("priv/repo/seeds.exs")

      assert {:ok, user} =
               Atlas.Accounts.User
               |> Ash.Query.filter(email == "admin@dev.local")
               |> Ash.read_one(authorize?: false)

      assert to_string(user.email) == "admin@dev.local"
      assert user.confirmed_at != nil
    end

    test "is idempotent — running twice does not error" do
      Code.eval_file("priv/repo/seeds.exs")
      Code.eval_file("priv/repo/seeds.exs")

      assert {:ok, [_single_user]} =
               Atlas.Accounts.User
               |> Ash.Query.filter(email == "admin@dev.local")
               |> Ash.read(authorize?: false)
    end
  end
end
