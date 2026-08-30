defmodule AgentSocial.WorkersTest do
  use AgentSocial.DataCase

  alias AgentSocial.Connections
  alias AgentSocial.Connections.{CheckinWorker, ConnectionCheckin}
  alias AgentSocial.Operations.InboxEvent
  alias AgentSocial.Reputation

  test "due check-ins reach the inbox and update human-owned reputation" do
    first = actor()
    second = actor()
    checkin = connection_checkin(first, second)

    due = DateTime.add(DateTime.utc_now(), -1, :minute)
    checkin = checkin |> Ecto.Changeset.change(due_at: due) |> Repo.update!()

    assert :ok = CheckinWorker.perform(%Oban.Job{args: %{"checkin_id" => checkin.id}})

    assert Repo.exists?(
             from event in InboxEvent,
               where:
                 event.human_id == ^first.human.id and event.type == "connection.checkin_due" and
                   event.resource_id == ^checkin.id
           )

    assert {:ok, response} =
             Connections.submit_checkin(first.binding, checkin.id, %{
               "active" => true,
               "useful" => true,
               "feedback" => %{"note" => "still useful"}
             })

    assert response.responded_at
    assert {:ok, snapshot} = Reputation.recalculate(first.human.id)
    assert Decimal.compare(snapshot.score, Decimal.new(20)) == :gt
  end

  test "an early check-in remains unknown and cannot be submitted" do
    first = actor()
    second = actor()
    checkin = connection_checkin(first, second)

    assert {:error, :checkin_not_due} =
             Connections.submit_checkin(first.binding, checkin.id, %{
               "active" => false,
               "useful" => false
             })

    assert {:snooze, seconds} =
             CheckinWorker.perform(%Oban.Job{args: %{"checkin_id" => checkin.id}})

    assert seconds > 0
    refute Repo.exists?(from event in InboxEvent, where: event.resource_id == ^checkin.id)
  end

  defp connection_checkin(first, second) do
    {:ok, thread} =
      Connections.open_thread(first.binding, second.human.id, "cofounder", "worker-thread")

    {:ok, proposal} =
      Connections.propose_introduction(
        first.binding,
        thread.id,
        "Test durable retention",
        "worker-intro"
      )

    {:ok, _, _} =
      Connections.decide_approval(proposal.development_approval_tokens.proposer, "approved")

    {:ok, _, connection} =
      Connections.decide_approval(proposal.development_approval_tokens.recipient, "approved")

    Repo.get_by!(ConnectionCheckin,
      connection_id: connection.id,
      human_id: first.human.id,
      period_days: 30
    )
  end
end
