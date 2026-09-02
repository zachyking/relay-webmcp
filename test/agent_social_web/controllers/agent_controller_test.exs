defmodule AgentSocialWeb.AgentControllerTest do
  use AgentSocialWeb.ConnCase

  alias AgentSocial.Identity
  alias AgentSocial.Operations.AuditEvent
  alias AgentSocial.Repo

  test "bearer API writes replay successful idempotent retries", %{conn: conn} do
    actor = actor()

    headers = [
      {"authorization", "Bearer #{actor.token}"},
      {"idempotency-key", "publish-once-001"}
    ]

    conn =
      Enum.reduce(headers, conn, fn {key, value}, conn -> put_req_header(conn, key, value) end)

    assert %{"data" => %{"id" => id}} =
             conn
             |> post(~p"/api/v1/posts", content_attrs(%{"visibility" => "public"}))
             |> json_response(201)

    assert is_binary(id)

    replay =
      build_conn()
      |> put_req_header("authorization", "Bearer #{actor.token}")
      |> put_req_header("idempotency-key", "publish-once-001")
      |> post(~p"/api/v1/posts", content_attrs(%{"visibility" => "public"}))

    assert %{"data" => %{"id" => ^id}} = json_response(replay, 201)
    assert get_resp_header(replay, "idempotent-replayed") == ["true"]

    mismatch =
      build_conn()
      |> put_req_header("authorization", "Bearer #{actor.token}")
      |> put_req_header("idempotency-key", "publish-once-001")
      |> post(~p"/api/v1/posts", content_attrs(%{"visibility" => "network"}))

    assert %{"error" => %{"code" => "idempotency_payload_mismatch"}} =
             json_response(mismatch, 409)
  end

  test "an authenticated browser agent session can publish a Studio draft", %{conn: conn} do
    actor = actor()

    session_conn =
      conn
      |> post(~p"/api/v1/browser-session", %{"bearer_token" => actor.token})

    assert json_response(session_conn, 200)["data"]["authenticated"] == true

    response =
      session_conn
      |> recycle()
      |> put_req_header("idempotency-key", "studio-browser-publish-001")
      |> post(
        ~p"/api/v1/posts",
        content_attrs(%{
          "rankable_metadata" => %{
            "summary" => "Exact visible Studio draft",
            "collaboration_surface" => "shared_review_room"
          },
          "opaque_payload" => "The exact draft approved in the browser."
        })
      )

    assert %{
             "data" => %{
               "id" => id,
               "opaque_payload" => "The exact draft approved in the browser."
             }
           } = json_response(response, 201)

    assert is_binary(id)
  end

  test "unauthenticated callers receive protected-resource discovery", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/feed")
    assert json_response(conn, 401)["error"]["code"] == "unauthorized"
    assert [challenge] = get_resp_header(conn, "www-authenticate")
    assert challenge =~ "oauth-protected-resource"
  end

  test "service-signed gateway calls are nonce-bound and replay protected" do
    actor = actor()
    previous = System.get_env("MCP_INTERNAL_SECRET")
    System.put_env("MCP_INTERNAL_SECRET", "gateway-test-secret")

    on_exit(fn ->
      if previous,
        do: System.put_env("MCP_INTERNAL_SECRET", previous),
        else: System.delete_env("MCP_INTERNAL_SECRET")
    end)

    timestamp = System.system_time(:second) |> Integer.to_string()
    nonce = "test-nonce-#{Ecto.UUID.generate()}"
    scopes = "feed:read"
    client_id = "codex-gateway-test"

    input =
      Enum.join(
        [
          timestamp,
          nonce,
          "human_id",
          actor.human.id,
          scopes,
          client_id,
          "",
          "GET",
          "/api/v1/feed"
        ],
        ":"
      )

    signature =
      :crypto.mac(:hmac, :sha256, "gateway-test-secret", input)
      |> Base.url_encode64(padding: false)

    signed = fn ->
      build_conn()
      |> put_req_header("x-agent-human-id", actor.human.id)
      |> put_req_header("x-agent-scopes", scopes)
      |> put_req_header("x-agent-client-id", client_id)
      |> put_req_header("x-agent-timestamp", timestamp)
      |> put_req_header("x-agent-nonce", nonce)
      |> put_req_header("x-agent-signature", signature)
    end

    assert signed.() |> get(~p"/api/v1/feed") |> json_response(200)
    assert signed.() |> get(~p"/api/v1/feed") |> json_response(401)
  end

  test "gateway delegated scopes are intersected with the stored binding", %{conn: conn} do
    actor = actor()
    previous = System.get_env("MCP_INTERNAL_SECRET")
    System.put_env("MCP_INTERNAL_SECRET", "scope-test-secret")

    on_exit(fn ->
      if previous,
        do: System.put_env("MCP_INTERNAL_SECRET", previous),
        else: System.delete_env("MCP_INTERNAL_SECRET")
    end)

    timestamp = System.system_time(:second) |> Integer.to_string()
    nonce = "scope-nonce-#{Ecto.UUID.generate()}"
    scopes = "feed:read invented:admin"
    client_id = "limited-client"

    input =
      Enum.join(
        [
          timestamp,
          nonce,
          "human_id",
          actor.human.id,
          scopes,
          client_id,
          "",
          "GET",
          "/api/v1/profiles/me"
        ],
        ":"
      )

    signature =
      :crypto.mac(:hmac, :sha256, "scope-test-secret", input)
      |> Base.url_encode64(padding: false)

    response =
      conn
      |> put_req_header("x-agent-human-id", actor.human.id)
      |> put_req_header("x-agent-scopes", scopes)
      |> put_req_header("x-agent-client-id", client_id)
      |> put_req_header("x-agent-timestamp", timestamp)
      |> put_req_header("x-agent-nonce", nonce)
      |> put_req_header("x-agent-signature", signature)
      |> get(~p"/api/v1/profiles/me")

    assert json_response(response, 403)["error"]["code"] == "insufficient_scope"
  end

  test "successful mutations record complete agent provenance", %{conn: conn} do
    actor = actor()

    response =
      conn
      |> put_req_header("authorization", "Bearer #{actor.token}")
      |> put_req_header("idempotency-key", "profile-audit-001")
      |> put(~p"/api/v1/profiles/me/claims", %{
        "key" => "availability",
        "value" => %{"text" => "Open to customer conversations"},
        "visibility" => "network"
      })

    claim_id = json_response(response, 200)["data"]["id"]
    audit = Repo.get_by!(AuditEvent, event_type: "profile.claim_set", resource_id: claim_id)

    assert audit.actor_human_id == actor.human.id
    assert audit.agent_binding_id == actor.binding.id
    assert audit.agent_key_version == 1
    assert audit.client_id == actor.binding.client_id
    assert audit.policy_version == Identity.get_policy(actor.human.id).version
    assert audit.configuration_version == 1
    assert audit.idempotency_key == "profile-audit-001"
    assert audit.result_state == %{"visibility" => "network"}
  end

  test "network search returns direct profile matches without private claims", %{conn: conn} do
    viewer = actor()
    candidate = actor()

    {:ok, _} =
      Identity.upsert_profile_claim(candidate.binding, %{
        "key" => "opportunity",
        "value" => %{"text" => "seeking observability design partner"},
        "visibility" => "network",
        "rankable" => true
      })

    response =
      conn
      |> put_req_header("authorization", "Bearer #{viewer.token}")
      |> get(~p"/api/v1/search?q=observability&limit=10")
      |> json_response(200)

    assert [%{"result_type" => "profile", "profile" => %{"id" => candidate_id}}] =
             response["data"]

    assert candidate_id == candidate.human.id
  end
end
