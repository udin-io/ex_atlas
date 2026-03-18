defmodule Atlas.Infrastructure do
  use Ash.Domain, otp_app: :atlas, extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource Atlas.Infrastructure.App
    resource Atlas.Infrastructure.Machine
    resource Atlas.Infrastructure.Volume
    resource Atlas.Infrastructure.StorageBucket
  end
end
