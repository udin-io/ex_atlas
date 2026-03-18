# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs

# Create admin user
case Atlas.Accounts.User |> Ash.Query.filter(email == "admin@dev.local") |> Ash.read_one() do
  {:ok, nil} ->
    Atlas.Accounts.User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: "admin@dev.local",
      password: "Testpass!23",
      password_confirmation: "Testpass!23"
    })
    |> Ash.create!()

    IO.puts("Created admin user: admin@dev.local")

  {:ok, _user} ->
    IO.puts("Admin user already exists")
end
