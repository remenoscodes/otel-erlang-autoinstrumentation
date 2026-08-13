defmodule VanillaApp.PingWorker do
  @moduledoc """
  Trivial Oban worker used only to prove job execution end to end. Like
  ItemController.outbound/2's Req usage, vanilla_app never imports or calls
  OpentelemetryOban anywhere — the spike proves the job span appears without
  it.
  """
  use Oban.Worker, queue: :default

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: :ok
end
