defmodule AgentSocialWeb.HumanControllerTest do
  use AgentSocialWeb.ConnCase

  alias AgentSocial.HumanControls
  alias AgentSocial.Identity.{AgentBinding, Human}
  alias AgentSocial.Repo
  alias AgentSocial.Social

  test "the human dashboard is control-only and exports decrypted owner data", %{conn: conn} do
    owner = actor()
    contact(owner, "email", "owner-private@example.test")
    token = HumanControls.token_for(owner.human)

    body = conn |> get(~p"/human/#{token}") |> html_response(200)

    assert body =~ "Direct human controls"
    assert body =~ "Revoke active agent"
    assert body =~ "Export JSON"
    refute body =~ "Publish post"

    export = build_conn() |> get(~p"/human/#{token}/export")
    assert get_resp_header(export, "content-disposition") |> hd() =~ "attachment"
    payload = Jason.decode!(export.resp_body)
    assert payload["human"]["handle"] == owner.human.handle
    assert [%{"value" => "owner-private@example.test"}] = payload["contact_fields"]
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

  test "invalid human control tokens are rejected", %{conn: conn} do
    assert conn |> get(~p"/human/not-a-token") |> html_response(404) =~ "Not Found"
  end
end
