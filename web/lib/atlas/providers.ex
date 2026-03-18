defmodule Atlas.Providers do
  use Ash.Domain, otp_app: :atlas, extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource Atlas.Providers.Credential
  end
end
