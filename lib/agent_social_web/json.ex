defmodule AgentSocialWeb.JSON do
  @moduledoc false

  def human(%{id: id, handle: handle, reputation: reputation, claims: claims}) do
    %{
      id: id,
      handle: handle,
      reputation: decimal_number(reputation),
      claims: Enum.map(claims, &profile_claim/1)
    }
  end

  def profile_claim(claim),
    do: Map.take(claim, [:id, :key, :value, :visibility, :rankable, :inserted_at, :updated_at])

  def policy(policy) do
    Map.take(policy, [
      :version,
      :relationship_modes,
      :topic_preferences,
      :daily_post_limit,
      :daily_message_limit,
      :allow_inbound_threads,
      :require_intro_approval,
      :require_contact_approval,
      :confirmation_requirements,
      :disclosure_rules,
      :updated_at
    ])
  end

  def profile_search_result(profile),
    do: %{result_type: "profile", profile: human(profile), untrusted_content: true}

  def content_search_result(content),
    do: %{result_type: "content", content: content(content), untrusted_content: true}

  def content(content) do
    %{
      id: content.id,
      author_human_id: content.author_human_id,
      author_handle: loaded(content, :author, :handle),
      author_reputation: loaded(content, :author, :reputation) |> decimal_number(),
      agent_binding_id: content.agent_binding_id,
      community_id: content.community_id,
      community_slug: loaded(content, :community, :slug),
      parent_id: content.parent_id,
      kind: content.kind,
      relationship_modes: content.relationship_modes,
      topic_ids: content.topic_ids,
      visibility: content.visibility,
      language: content.language,
      format: content.format,
      encoding: content.encoding,
      schema_uri: content.schema_uri,
      rankable_metadata: content.rankable_metadata,
      opaque_payload: content.opaque_payload,
      provenance: content.provenance,
      created_at: content.inserted_at,
      expires_at: content.expires_at,
      ranking: %{
        score: content.ranking_score,
        configuration_version: content.ranking_configuration_version
      },
      untrusted_content: true
    }
  end

  def community(community),
    do:
      Map.take(community, [
        :id,
        :slug,
        :name,
        :description,
        :creator_human_id,
        :visibility,
        :admission,
        :relationship_modes,
        :rules,
        :status,
        :inserted_at
      ])

  def thread(thread),
    do:
      Map.take(thread, [
        :id,
        :initiator_human_id,
        :recipient_human_id,
        :relationship_mode,
        :status,
        :last_message_at,
        :inserted_at
      ])

  def message(message) do
    Map.take(message, [
      :id,
      :thread_id,
      :sender_human_id,
      :format,
      :encoding,
      :schema_uri,
      :opaque_payload,
      :metadata,
      :inserted_at
    ])
    |> Map.put(:untrusted_content, true)
  end

  def inbox(event),
    do:
      Map.take(event, [
        :id,
        :type,
        :resource_type,
        :resource_id,
        :metadata,
        :read_at,
        :inserted_at
      ])

  def approval(approval),
    do:
      Map.take(approval, [
        :id,
        :action,
        :resource_type,
        :resource_id,
        :recipient_human_id,
        :fields,
        :purpose,
        :grant_expires_at,
        :status,
        :expires_at,
        :decided_at
      ])

  def proposal(proposal),
    do:
      Map.take(proposal, [
        :id,
        :thread_id,
        :proposer_human_id,
        :recipient_human_id,
        :purpose,
        :status,
        :expires_at,
        :inserted_at
      ])

  def contact(contact), do: contact

  defp loaded(struct, association, field) do
    case Map.get(struct, association) do
      %Ecto.Association.NotLoaded{} -> nil
      nil -> nil
      value -> Map.get(value, field)
    end
  end

  defp decimal_number(%Decimal{} = value), do: Decimal.to_float(value)
  defp decimal_number(value), do: value
end
