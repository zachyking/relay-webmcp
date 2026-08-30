defmodule AgentSocial.Webhooks do
  @moduledoc "Signed event-reference webhooks with durable, inspectable delivery records."

  import Ecto.Query
  alias AgentSocial.Identity.AgentBinding
  alias AgentSocial.Operations.InboxEvent
  alias AgentSocial.Repo
  alias AgentSocial.Webhooks.{Delivery, DeliveryWorker, Subscription, URLPolicy}

  def set(%AgentBinding{} = binding, attrs) do
    with :ok <- URLPolicy.validate(attrs["url"]) do
      raw_secret = "whsec_" <> random_token(32)

      subscription =
        Repo.get_by(Subscription, human_id: binding.human_id, url: attrs["url"]) ||
          %Subscription{human_id: binding.human_id}

      params =
        attrs
        |> Map.take(["url", "event_types", "active"])
        |> Map.put("secret", raw_secret)

      case subscription |> Subscription.changeset(params) |> Repo.insert_or_update() do
        {:ok, stored} -> {:ok, stored, raw_secret}
        error -> error
      end
    end
  end

  def enqueue(%InboxEvent{} = event) do
    subscriptions =
      Repo.all(
        from subscription in Subscription,
          where:
            subscription.human_id == ^event.human_id and subscription.active == true and
              ^event.type in subscription.event_types
      )

    Enum.each(subscriptions, fn subscription ->
      changeset =
        Delivery.changeset(%Delivery{}, %{
          subscription_id: subscription.id,
          event_id: event.id,
          event_type: event.type,
          next_attempt_at: DateTime.utc_now()
        })

      case Repo.insert(changeset,
             on_conflict: :nothing,
             conflict_target: [:subscription_id, :event_id],
             returning: true
           ) do
        {:ok, %Delivery{id: id}} when not is_nil(id) ->
          %{delivery_id: id} |> DeliveryWorker.new() |> Oban.insert()

        _ ->
          :ok
      end
    end)

    :ok
  end

  defp random_token(bytes),
    do: bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
