defmodule VanillaAppWeb.FakeAdapter do
  # Req's :adapter option, as a module implementing run/1 (the
  # function-based form is deprecated as of Req 0.7). Replaces the
  # transport step with a canned response — no real network I/O, kept
  # hermetic like the rest of this spike.
  def run(request), do: {request, Req.Response.new(status: 200, body: "pong")}
end

defmodule VanillaAppWeb.ItemController do
  use Phoenix.Controller, formats: [:json]

  alias VanillaApp.{Item, Repo}

  def index(conn, _params) do
    items = Repo.all(Item)
    json(conn, %{count: length(items), items: Enum.map(items, & &1.name)})
  end

  # Proves the Req instrumentation without any real network I/O. This app
  # never imports or calls OpentelemetryReq — if a client span for this
  # request reaches the collector, that instrumentation was applied
  # entirely from outside.
  def outbound(conn, _params) do
    req =
      Req.new(base_url: "http://internal.invalid", adapter: VanillaAppWeb.FakeAdapter)

    {:ok, resp} = Req.get(req, url: "/ping")
    json(conn, %{outbound_status: resp.status})
  end
end
