defmodule AgentSocialWeb.HumanControllerTest do
  use AgentSocialWeb.ConnCase

  import Swoosh.TestAssertions

  alias AgentSocial.HumanControls
  alias AgentSocial.Connections.HumanApproval
  alias AgentSocial.Identity.{AgentBinding, Human}
  alias AgentSocial.Repo
  alias AgentSocial.Social

  setup do
    previous = Application.fetch_env!(:agent_social, AgentSocial.Notifier)

    Application.put_env(:agent_social, AgentSocial.Notifier,
      adapter: AgentSocial.Notifier.SMTPAdapter,
      from_address: "relay@example.test",
      from_name: "Relay"
    )

    on_exit(fn -> Application.put_env(:agent_social, AgentSocial.Notifier, previous) end)
  end

  test "the human dashboard is control-only and exports decrypted owner data", %{conn: conn} do
    owner = actor()
    contact(owner, "email", "owner-private@example.test")
    token = HumanControls.token_for(owner.human)

    body = conn |> get(~p"/human/#{token}") |> html_response(200)

    assert body =~ "Direct human controls"
    assert body =~ "Revoke active agent"
    assert body =~ "Export JSON"
    assert body =~ "expires 60 minutes"
    refute body =~ "Publish post"

    export = build_conn() |> get(~p"/human/#{token}/export")
    assert get_resp_header(export, "content-disposition") |> hd() =~ "attachment"
    payload = Jason.decode!(export.resp_body)
    assert payload["human"]["handle"] == owner.human.handle
    assert [%{"value" => "owner-private@example.test"}] = payload["contact_fields"]
  end

  test "a human can request a fresh short-lived control link", %{conn: conn} do
    owner = actor(%{email: "owner-access@example.test"})

    request = conn |> get(~p"/human-access") |> html_response(200)
    assert request =~ "human-access-form"
    assert request =~ "human-access-submit"

    sent =
      build_conn()
      |> post(~p"/human-access", %{"email" => " OWNER-ACCESS@example.test "})
      |> html_response(200)

    assert sent =~ "human-access-sent"

    assert_email_sent(fn email ->
      assert email.to == [{"", owner.human.email}]
      assert email.subject == "Your Relay human control page"
      assert email.text_body =~ "expires in 60 minutes"
    end)
  end

  test "the dashboard expands exact agent content and approval context", %{conn: conn} do
    owner = actor()
    other = actor()
    token = HumanControls.token_for(owner.human)

    {:ok, content} =
      Social.publish(
        owner.binding,
        content_attrs(%{"opaque_payload" => "The exact words my agent published."}),
        "human-detail-content"
      )

    now = DateTime.utc_now()

    approval =
      %HumanApproval{}
      |> HumanApproval.changeset(%{
        human_id: owner.human.id,
        action: "approve_introduction",
        resource_type: "introduction",
        resource_id: Ecto.UUID.generate(),
        recipient_human_id: other.human.id,
        purpose: "Explore a climate hardware company together",
        token_digest: :crypto.hash(:sha256, "approval-token"),
        status: "approved",
        expires_at: DateTime.add(now, 86_400),
        decided_at: now
      })
      |> Repo.insert!()

    body = conn |> get(~p"/human/#{token}") |> html_response(200)

    assert body =~ "audit-"
    assert body =~ "The exact words my agent published."
    assert body =~ "approval-#{approval.id}"
    assert body =~ "Explore a climate hardware company together"
    assert body =~ "@#{other.human.handle}"
    assert body =~ content.id
  end

  test "a human can revoke their active agent directly", %{conn: conn} do
    owner = actor()
    token = HumanControls.token_for(owner.human)

    response = post(conn, ~p"/human/#{token}/revoke-agent", %{})
    assert redirected_to(response) == ~p"/human/#{token}"
    refute Repo.get!(AgentBinding, owner.binding.id).active
  end

  test "deletion hides content immediately and marks purge within 30 days", %{conn: conn} do
    owner = actor()
    token = HumanControls.token_for(owner.human)

    {:ok, content} =
      Social.publish(
        owner.binding,
        content_attrs(%{"visibility" => "public"}),
        "human-delete-content"
      )

    response = post(conn, ~p"/human/#{token}/delete", %{"confirmation" => "DELETE"})
    assert html_response(response, 200) =~ "Deletion started"

    human = Repo.get!(Human, owner.human.id)
    assert human.status == "deleting"
    assert DateTime.diff(human.purge_after, DateTime.utc_now(), :day) in 29..30
    assert {:error, :not_found} = Social.get_item(content.id, nil)
  end

  test "invalid and expired human control tokens offer recovery", %{conn: conn} do
    assert conn |> get(~p"/human/not-a-token") |> html_response(401) =~
             "Request a new link"

    owner = actor()

    expired =
      HumanControls.token_for(owner.human,
        signed_at: System.system_time(:second) - HumanControls.token_lifetime_seconds() - 5
      )

    assert build_conn() |> get(~p"/human/#{expired}") |> html_response(401) =~
             "This control link has expired."
  end
end
