defmodule VanillaApp.Repo do
  use Ecto.Repo, otp_app: :vanilla_app, adapter: Ecto.Adapters.SQLite3
end
