defmodule AgentSocialWeb.StudioReviewControllerTest do
  use AgentSocialWeb.ConnCase

  alias AgentSocial.Repo
  alias AgentSocial.Studio.ReviewSession

  test "a secure review link restores, reviews, revises, and publishes across devices", %{
    conn: conn
  } do
    actor = actor()

    created =
      conn
      |> put_req_header("authorization", "Bearer #{actor.token}")
      |> put_req_header("idempotency-key", "studio-room-create-001")
      |> post(~p"/api/v1/studio-sessions", draft_attrs())
      |> json_response(201)
      |> Map.fetch!("data")

    assert created["draft_version"] == 1
    assert created["review_url"] =~ "/studio/review#rvw_"
    token = created["review_url"] |> URI.parse() |> Map.fetch!(:fragment)

    session = Repo.get!(ReviewSession, created["id"])
    assert session.token_digest == :crypto.hash(:sha256, token)

    restored =
      build_conn()
      |> review_token(token)
      |> get(~p"/api/v1/studio-review")
      |> json_response(200)
      |> Map.fetch!("data")

    assert restored["draft"]["body"] == draft_attrs()["body"]
    assert restored["review"]["ready"] == false

    review = %{
      "draft_version" => 1,
      "overall_note" => "Make the ending more direct.",
      "paragraph_feedback" => %{
        "0" => %{"decision" => "keep", "comment" => ""},
        "1" => %{"decision" => "rewrite", "comment" => "End with an invitation."}
      }
    }

    saved =
      build_conn()
      |> review_token(token)
      |> put(~p"/api/v1/studio-review", review)
      |> json_response(200)
      |> Map.fetch!("data")

    assert saved["review"]["overall_note"] == "Make the ending more direct."

    ready =
      build_conn()
      |> review_token(token)
      |> post(~p"/api/v1/studio-review/ready", %{"draft_version" => 1})
      |> json_response(200)
      |> Map.fetch!("data")

    assert ready["review"]["ready"] == true

    agent_read =
      build_conn()
      |> put_req_header("authorization", "Bearer #{actor.token}")
      |> get(~p"/api/v1/studio-sessions/#{created["id"]}")
      |> json_response(200)
      |> Map.fetch!("data")

    assert agent_read["review"]["ready"] == true

    revised_attrs =
      draft_attrs(%{
        "based_on_version" => 1,
        "body" => "Unfinished ideas should travel sooner.\n\nWho wants to build that way?",
        "agent_note" => "Kept the premise and rewrote the ending as an invitation."
      })

    revised =
      build_conn()
      |> put_req_header("authorization", "Bearer #{actor.token}")
      |> put_req_header("idempotency-key", "studio-room-revise-001")
      |> put(~p"/api/v1/studio-sessions/#{created["id"]}", revised_attrs)
      |> json_response(200)
      |> Map.fetch!("data")

    assert revised["draft_version"] == 2
    assert revised["review"]["ready"] == false

    restored_again =
      build_conn()
      |> review_token(token)
      |> get(~p"/api/v1/studio-review")
      |> json_response(200)
      |> Map.fetch!("data")

    assert restored_again["draft_version"] == 2
    assert restored_again["draft"]["body"] == revised_attrs["body"]

    published =
      build_conn()
      |> review_token(token)
      |> put_req_header("idempotency-key", "studio-room-publish-001")
      |> post(~p"/api/v1/studio-review/publish", %{})
      |> json_response(200)
      |> Map.fetch!("data")

    assert published["status"] == "published"
    assert published["published"]["url"] =~ "/posts/"

    public_post =
      build_conn()
      |> get(published["published"]["url"])
      |> html_response(200)

    assert public_post =~ "Who wants to build that way?"
  end

  test "review links are required and stale versions cannot overwrite a revision", %{conn: conn} do
    actor = actor()

    created =
      conn
      |> put_req_header("authorization", "Bearer #{actor.token}")
      |> put_req_header("idempotency-key", "studio-room-create-002")
      |> post(~p"/api/v1/studio-sessions", draft_attrs())
      |> json_response(201)
      |> Map.fetch!("data")

    token = created["review_url"] |> URI.parse() |> Map.fetch!(:fragment)

    assert %{"error" => %{"code" => "review_not_ready"}} =
             build_conn()
             |> put_req_header("authorization", "Bearer #{actor.token}")
             |> put_req_header("idempotency-key", "studio-room-too-early-002")
             |> put(
               ~p"/api/v1/studio-sessions/#{created["id"]}",
               draft_attrs(%{"based_on_version" => 1})
             )
             |> json_response(409)

    assert %{"error" => %{"code" => "review_token_required"}} =
             build_conn()
             |> get(~p"/api/v1/studio-review")
             |> json_response(401)

    assert %{"error" => %{"code" => "stale_draft_version"}} =
             build_conn()
             |> review_token(token)
             |> put(~p"/api/v1/studio-review", %{
               "draft_version" => 99,
               "overall_note" => "stale",
               "paragraph_feedback" => %{}
             })
             |> json_response(409)
  end

  test "the durable human review page exposes Studio tools", %{conn: conn} do
    body = conn |> get(~p"/studio/review") |> html_response(200)
    assert body =~ "collab-studio"
    assert body =~ "Private review link"
    assert body =~ "opens on another device"
  end

  defp review_token(conn, token), do: put_req_header(conn, "x-relay-review-token", token)

  defp draft_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "summary" => "Share unfinished ideas sooner",
        "body" =>
          "What if unfinished ideas travelled sooner?\n\nThe rough edges might find collaborators.",
        "relationship_modes" => ["cofounder", "friendship"],
        "topic_ids" => ["webmcp", "collaboration"],
        "agent_note" => "Started from the unresolved product question."
      },
      overrides
    )
  end
end
