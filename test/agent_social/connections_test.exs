defmodule AgentSocial.ConnectionsTest do
  use AgentSocial.DataCase

  alias AgentSocial.Connections
  alias AgentSocial.Connections.{Connection, ConnectionCheckin}

  test "introduction requires both humans and contact release requires its own owner approval" do
    proposer = actor()
    recipient = actor()
    contact(recipient, "email", "recipient@example.test")

    assert {:ok, thread} =
             Connections.open_thread(
               proposer.binding,
               recipient.human.id,
               "cofounder",
               "thread-key"
             )

    assert {:ok, result} =
             Connections.propose_introduction(
               proposer.binding,
               thread.id,
               "Build durable agent infrastructure",
               "intro-key"
             )

    tokens = result.development_approval_tokens

    assert {:ok, proposer_approval, _, _} = Connections.get_approval(tokens.proposer)
    assert proposer_approval.purpose == "Build durable agent infrastructure"

    assert {:ok, _, :awaiting_other_human} =
             Connections.decide_approval(tokens.proposer, "approved")

    assert Repo.aggregate(Connection, :count) == 0

    assert {:ok, _, %Connection{} = connection} =
             Connections.decide_approval(tokens.recipient, "approved")

    assert Repo.aggregate(ConnectionCheckin, :count) == 4

    assert {:ok, request} =
             Connections.request_contact_release(
               proposer.binding,
               connection.id,
               ["email"],
               "Continue the cofounder conversation",
               14,
               "contact-key"
             )

    assert request.approval.human_id == recipient.human.id
    assert request.approval.recipient_human_id == proposer.human.id
    assert request.approval.purpose == "Continue the cofounder conversation"

    assert {:ok, _, _grant} =
             Connections.decide_approval(request.development_approval_token, "approved")

    assert {:ok, [%{kind: "email", value: "recipient@example.test"}]} =
             Connections.get_released_contacts(proposer.binding, connection.id)
  end
end
