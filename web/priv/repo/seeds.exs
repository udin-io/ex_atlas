# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs

# Create admin user
require Ash.Query

case Atlas.Accounts.User
     |> Ash.Query.filter(email == "admin@dev.local")
     |> Ash.read_one(authorize?: false) do
  {:ok, nil} ->
    user =
      Atlas.Accounts.User
      |> Ash.Changeset.for_create(:register_with_password, %{
        email: "admin@dev.local",
        password: "Testpass!23",
        password_confirmation: "Testpass!23"
      })
      |> Ash.create!(authorize?: false)

    # Confirm the user so they can sign in immediately in dev
    user
    |> Ecto.Changeset.change(%{confirmed_at: DateTime.utc_now()})
    |> Atlas.Repo.update!()

    IO.puts("Created admin user: admin@dev.local")

  {:ok, _user} ->
    IO.puts("Admin user already exists")

  {:error, reason} ->
    IO.puts("Error checking for admin user: #{inspect(reason)}")
end
