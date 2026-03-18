defmodule Atlas.Accounts do
  use Ash.Domain, otp_app: :atlas, extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource Atlas.Accounts.Token
    resource Atlas.Accounts.User
  end
end
