defmodule AgentSocial.Operations.InboxDispatchWorker do
  @moduledoc "Reliably fans durable inbox references out to matching signed webhooks."

  use Oban.Worker, queue: :webhooks, max_attempts: 10

  import Ecto.Query
  alias AgentSocial.Operations.InboxEvent
  alias AgentSocial.{Repo, Webhooks}

  @impl Oban.Worker
  def perform(_job) do
    Repo.transaction(fn ->
      events =
        Repo.all(
          from event in InboxEvent,
            where: is_nil(event.webhook_dispatched_at),
            order_by: [asc: event.inserted_at, asc: event.id],
            limit: 500,
            lock: "FOR UPDATE SKIP LOCKED"
        )

      now = DateTime.utc_now()

      Enum.each(events, fn event ->
        :ok = Webhooks.enqueue(event)

        event
        |> Ecto.Changeset.change(webhook_dispatched_at: now)
        |> Repo.update!()
      end)

      length(events)
    end)

    :ok
  end
end
