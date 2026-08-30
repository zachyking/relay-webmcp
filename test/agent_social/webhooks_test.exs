defmodule AgentSocial.WebhooksTest do
  use AgentSocial.DataCase

  alias AgentSocial.Webhooks.{Delivery, DeliveryWorker, Subscription}

  setup {Req.Test, :verify_on_exit!}

  test "deliveries contain only a signed event reference and a replay-deduplication ID" do
    owner = actor()
    parent = self()
    previous = Application.get_env(:agent_social, :webhook_req_options)
    Application.put_env(:agent_social, :webhook_req_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:agent_social, :webhook_req_options, previous),
        else: Application.delete_env(:agent_social, :webhook_req_options)
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      send(parent, {:webhook_request, conn.req_headers, Req.Test.raw_body(conn)})
      Plug.Conn.send_resp(conn, 204, "")
    end)

    subscription =
      %Subscription{human_id: owner.human.id}
      |> Subscription.changeset(%{
        url: "https://1.1.1.1/hook",
        secret: "whsec_test_signing_secret",
        event_types: ["thread.message"]
      })
      |> Repo.insert!()

    event_id = Ecto.UUID.generate()

    delivery =
      %Delivery{}
      |> Delivery.changeset(%{
        subscription_id: subscription.id,
        event_id: event_id,
        event_type: "thread.message",
        next_attempt_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    assert :ok =
             DeliveryWorker.perform(%Oban.Job{
               args: %{"delivery_id" => delivery.id},
               attempt: 1
             })

    assert_receive {:webhook_request, headers, body}
    assert Jason.decode!(body) == %{"event_id" => event_id, "type" => "thread.message"}

    timestamp = header(headers, "x-relay-timestamp")
    signature = header(headers, "x-relay-signature")
    assert header(headers, "x-relay-delivery") == delivery.id

    expected =
      :crypto.mac(:hmac, :sha256, subscription.secret, timestamp <> "." <> body)
      |> Base.url_encode64(padding: false)

    assert signature == "v1=" <> expected
    assert Repo.get!(Delivery, delivery.id).status == "delivered"
  end

  defp header(headers, name), do: headers |> List.keyfind(name, 0) |> elem(1)
end
