defmodule AgentSocial.Webhooks.DeliveryWorker do
  use Oban.Worker,
    queue: :webhooks,
    max_attempts: 8,
    unique: [period: :infinity, fields: [:args]]

  alias AgentSocial.Repo
  alias AgentSocial.Webhooks.{Delivery, Subscription, URLPolicy}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"delivery_id" => delivery_id}, attempt: attempt}) do
    delivery = Repo.get!(Delivery, delivery_id) |> Repo.preload(:subscription)

    with %Subscription{active: true} = subscription <- delivery.subscription,
         :ok <- URLPolicy.validate(subscription.url),
         {:ok, status} <- deliver(subscription, delivery) do
      delivery
      |> Delivery.changeset(%{
        status: "delivered",
        attempt_count: attempt,
        last_status: status,
        delivered_at: DateTime.utc_now(),
        last_error: nil,
        next_attempt_at: nil
      })
      |> Repo.update()

      :ok
    else
      reason ->
        dead? = attempt >= 8
        delay = min(round(:math.pow(2, attempt) * 15), 3_600)

        delivery
        |> Delivery.changeset(%{
          status: if(dead?, do: "dead", else: "pending"),
          attempt_count: attempt,
          last_error: inspect(reason),
          next_attempt_at:
            if(dead?, do: nil, else: DateTime.add(DateTime.utc_now(), delay, :second))
        })
        |> Repo.update()

        if dead?, do: {:discard, reason}, else: {:error, reason}
    end
  end

  defp deliver(subscription, delivery) do
    timestamp = System.system_time(:second) |> Integer.to_string()
    body = Jason.encode!(%{event_id: delivery.event_id, type: delivery.event_type})

    signature =
      :crypto.mac(:hmac, :sha256, subscription.secret, timestamp <> "." <> body)
      |> Base.url_encode64(padding: false)

    options = [
      body: body,
      headers: [
        {"content-type", "application/json"},
        {"x-relay-delivery", delivery.id},
        {"x-relay-timestamp", timestamp},
        {"x-relay-signature", "v1=" <> signature}
      ],
      redirect: false,
      receive_timeout: 10_000
    ]

    options = Keyword.merge(options, Application.get_env(:agent_social, :webhook_req_options, []))

    case Req.post(subscription.url, options) do
      {:ok, %{status: status}} when status in 200..299 -> {:ok, status}
      {:ok, %{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
