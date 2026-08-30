defmodule AgentSocial.SocialTest do
  use AgentSocial.DataCase

  alias AgentSocial.{Safety, Social}
  alias AgentSocial.Connections
  alias AgentSocial.Identity
  alias AgentSocial.Social.CommunityRule

  test "visibility is enforced and blocks take precedence" do
    author = actor()
    viewer = actor()

    assert {:ok, public} =
             Social.publish(
               author.binding,
               content_attrs(%{"visibility" => "public"}),
               "public-key"
             )

    assert {:ok, network} =
             Social.publish(
               author.binding,
               content_attrs(%{"visibility" => "network"}),
               "network-key"
             )

    assert {:ok, _} = Social.get_item(public.id, nil)
    assert {:error, :not_found} = Social.get_item(network.id, nil)
    assert {:ok, _} = Social.get_item(network.id, viewer.human.id)

    assert {:ok, _block} = Safety.block(viewer.binding, author.human.id, "not relevant")
    assert {:error, :not_found} = Social.get_item(public.id, viewer.human.id)
  end

  test "opaque payload accepts JSON but rejects payloads over 32 KB" do
    author = actor()

    assert {:ok, json_item} =
             Social.publish(
               author.binding,
               content_attrs(%{
                 "format" => "application/json",
                 "opaque_payload" => %{"dialect" => "A↔B"}
               }),
               "json-key"
             )

    assert Jason.decode!(json_item.opaque_payload) == %{"dialect" => "A↔B"}

    assert {:error, {:content, changeset}} =
             Social.publish(
               author.binding,
               content_attrs(%{"opaque_payload" => String.duplicate("x", 32_769)}),
               "oversize-key"
             )

    assert "exceeds 32768 bytes" in errors_on(changeset).opaque_payload
  end

  test "connection profile claims and connection content require an active connection" do
    author = actor()
    stranger = actor()

    {:ok, claim} =
      Identity.upsert_profile_claim(author.binding, %{
        "key" => "connection_note",
        "value" => %{"text" => "for confirmed people"},
        "visibility" => "connection"
      })

    assert claim.id not in Enum.map(
             Identity.get_profile(author.human.id, stranger.human.id).claims,
             & &1.id
           )

    {:ok, thread} =
      Connections.open_thread(author.binding, stranger.human.id, "friendship", "connect-thread")

    {:ok, proposal} =
      Connections.propose_introduction(
        author.binding,
        thread.id,
        "Stay in touch",
        "connect-intro"
      )

    {:ok, _, _} =
      Connections.decide_approval(proposal.development_approval_tokens.proposer, "approved")

    {:ok, _, _connection} =
      Connections.decide_approval(proposal.development_approval_tokens.recipient, "approved")

    assert claim.id in Enum.map(
             Identity.get_profile(author.human.id, stranger.human.id).claims,
             & &1.id
           )

    {:ok, content} =
      Social.publish(
        author.binding,
        content_attrs(%{"visibility" => "connection"}),
        "connection-content"
      )

    assert {:ok, _} = Social.get_item(content.id, stranger.human.id)
    assert {:error, :not_found} = Social.get_item(content.id, actor().human.id)
  end

  test "custom content requires a schema and bounded rankable metadata" do
    author = actor()

    assert {:error, {:content, changeset}} =
             Social.publish(
               author.binding,
               content_attrs(%{"kind" => "custom"}),
               "custom-no-schema"
             )

    assert "is required for custom content" in errors_on(changeset).schema_uri

    assert {:ok, custom} =
             Social.publish(
               author.binding,
               content_attrs(%{
                 "kind" => "custom",
                 "schema_uri" => "https://schemas.example/agent-opportunity/v1"
               }),
               "custom-with-schema"
             )

    assert custom.schema_uri == "https://schemas.example/agent-opportunity/v1"

    too_many = Map.new(1..51, &{"field_#{&1}", &1})

    assert {:error, {:content, oversized}} =
             Social.publish(
               author.binding,
               content_attrs(%{"rankable_metadata" => too_many}),
               "rankable-too-many"
             )

    assert "has too many fields" in errors_on(oversized).rankable_metadata
  end

  test "community owners can moderate local content but ordinary members cannot" do
    owner = actor()
    member = actor()

    {:ok, community} =
      Social.create_community(owner.binding, %{
        "slug" => "systems-#{System.unique_integer([:positive])}",
        "name" => "Systems",
        "relationship_modes" => ["cofounder"],
        "admission" => "open"
      })

    {:ok, _} = Social.join_community(member.binding, community.id, "join-community")

    {:ok, content} =
      Social.publish(
        member.binding,
        content_attrs(%{
          "community_id" => community.id,
          "visibility" => "community",
          "relationship_modes" => ["cofounder"]
        }),
        "community-content"
      )

    attrs = %{
      "subject_type" => "content",
      "subject_id" => content.id,
      "action" => "remove_content",
      "reason" => %{"rule" => "local-1"}
    }

    assert {:error, :not_permitted} =
             Social.moderate_community(member.binding, community.id, attrs, "member-moderation")

    assert {:ok, action} =
             Social.moderate_community(owner.binding, community.id, attrs, "owner-moderation")

    assert action.action == "remove_content"
    assert {:error, :not_found} = Social.get_item(content.id, owner.human.id)

    assert {:error, :not_permitted} =
             Social.set_community_rules(
               member.binding,
               community.id,
               %{"rules" => %{"be_specific" => true}},
               "member-rules"
             )

    assert {:ok, rule} =
             Social.set_community_rules(
               owner.binding,
               community.id,
               %{
                 "rules" => %{"be_specific" => true},
                 "relationship_modes" => ["cofounder", "business_partner"]
               },
               "owner-rules"
             )

    assert rule.version == 2
    assert Repo.aggregate(CommunityRule, :count) == 2
  end

  test "profile discovery searches only rankable network metadata and respects blocks" do
    viewer = actor()
    match = actor()

    {:ok, _} =
      Identity.upsert_profile_claim(match.binding, %{
        "key" => "looking_for",
        "value" => %{"text" => "distributed systems cofounder"},
        "visibility" => "network",
        "rankable" => true
      })

    {:ok, _} =
      Identity.upsert_profile_claim(match.binding, %{
        "key" => "private_note",
        "value" => %{"text" => "saffron-secret-term"},
        "visibility" => "private",
        "rankable" => true
      })

    assert [%{id: match_id}] = Identity.search_profiles(viewer.human.id, "distributed systems")
    assert match_id == match.human.id
    assert [] == Identity.search_profiles(viewer.human.id, "saffron-secret-term")

    {:ok, _} = Safety.block(viewer.binding, match.human.id)
    assert [] == Identity.search_profiles(viewer.human.id, "distributed systems")
  end
end
