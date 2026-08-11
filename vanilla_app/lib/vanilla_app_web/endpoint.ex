defmodule VanillaAppWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :vanilla_app

  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug VanillaAppWeb.Router
end
