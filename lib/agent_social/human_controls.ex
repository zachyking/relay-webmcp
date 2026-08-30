defmodule AgentSocial.HumanControls do
  @moduledoc "Direct human safety, consent, export, revocation, and deletion controls."

  import Ecto.Query
  alias AgentSocial.Connections.{Connection, ContactGrant, HumanApproval, Message, Thread}
  alias AgentSocial.Identity.{AgentBinding, ContactField, Human, Policy, ProfileClaim}
  alias AgentSocial.Operations.{AuditEvent, InboxEvent}
  alias AgentSocial.Safety.{Block, Report}
  alias AgentSocial.Social.ContentEnvelope
  alias AgentSocial.{Identity, Repo, Safety}

  @token_salt "human-control-v1"

  def token_for(%Human{id: id}),
    do: Phoenix.Token.sign(AgentSocialWeb.Endpoint, @token_salt, id)

  def verify_token(token) do
    max_age = Application.get_env(:agent_social, :human_control_token_max_age, 7 * 86_400)

    with {:ok, human_id} <-
           Phoenix.Token.verify(AgentSocialWeb.Endpoint, @token_salt, token, max_age: max_age),
         %Human{} = human <- Repo.get(Human, human_id) do
      {:ok, human}
    else
      nil -> {:error, :not_found}
      _ -> {:error, :invalid_or_expired_token}
    end
  end

  def snapshot(%Human{} = human) do
    bindings =
      Repo.all(
        from binding in AgentBinding,
          where: binding.human_id == ^human.id,
          order_by: [desc: binding.key_version]
      )

    connections =
      Repo.all(
        from connection in Connection,
          join: other in Human,
          on:
            other.id ==
              fragment(
                "CASE WHEN ? = ? THEN ? ELSE ? END",
                connection.human_a_id,
                type(^human.id, Ecto.UUID),
                connection.human_b_id,
                connection.human_a_id
              ),
          where: connection.human_a_id == ^human.id or connection.human_b_id == ^human.id,
          order_by: [desc: connection.activated_at],
          select: %{
            id: connection.id,
            other_human_id: other.id,
            other_handle: other.handle,
            relationship_mode: connection.relationship_mode,
            status: connection.status,
            activated_at: connection.activated_at
          }
      )

    %{
      human: human,
      bindings: bindings,
      connections: connections,
      grants:
        Repo.all(
          from grant in ContactGrant,
            where: grant.owner_human_id == ^human.id and is_nil(grant.revoked_at),
            order_by: [desc: grant.inserted_at]
        ),
      approvals:
        Repo.all(
          from approval in HumanApproval,
            where: approval.human_id == ^human.id,
            order_by: [desc: approval.inserted_at],
            limit: 25
        ),
      activity:
        Repo.all(
          from event in AuditEvent,
            where: event.actor_human_id == ^human.id,
            order_by: [desc: event.inserted_at],
            limit: 50
        ),
      blocks:
        Repo.all(
          from block in Block,
            where: block.blocker_human_id == ^human.id,
            order_by: [desc: block.inserted_at]
        )
    }
  end

  def export(%Human{} = human) do
    %{
      exported_at: DateTime.utc_now(),
      human:
        take(human, [
          :id,
          :handle,
          :email,
          :age_attested_at,
          :verified_at,
          :terms_version,
          :terms_accepted_at,
          :guidelines_version,
          :guidelines_accepted_at,
          :status,
          :reputation
        ])
        |> Map.update!(:reputation, &Decimal.to_float/1),
      agent_bindings:
        list(AgentBinding, where: [human_id: human.id])
        |> Enum.map(
          &take(&1, [
            :id,
            :client_name,
            :client_id,
            :scopes,
            :key_version,
            :active,
            :last_seen_at,
            :revoked_at,
            :inserted_at
          ])
        ),
      policy:
        Repo.get_by(Policy, human_id: human.id)
        |> take([
          :relationship_modes,
          :topic_preferences,
          :daily_post_limit,
          :daily_message_limit,
          :allow_inbound_threads,
          :require_intro_approval,
          :require_contact_approval,
          :disclosure_rules,
          :updated_at
        ]),
      profile_claims:
        list(ProfileClaim, where: [human_id: human.id])
        |> Enum.map(
          &take(&1, [:id, :key, :value, :visibility, :rankable, :inserted_at, :updated_at])
        ),
      contact_fields:
        list(ContactField, where: [human_id: human.id])
        |> Enum.map(&take(&1, [:id, :kind, :label, :value, :inserted_at, :updated_at])),
      content:
        list(ContentEnvelope, where: [author_human_id: human.id])
        |> Enum.map(
          &take(&1, [
            :id,
            :kind,
            :relationship_modes,
            :topic_ids,
            :visibility,
            :language,
            :format,
            :encoding,
            :schema_uri,
            :rankable_metadata,
            :opaque_payload,
            :provenance,
            :inserted_at,
            :expires_at,
            :deleted_at
          ])
        ),
      threads:
        Repo.all(
          from thread in Thread,
            where:
              thread.initiator_human_id == ^human.id or thread.recipient_human_id == ^human.id
        )
        |> Enum.map(
          &take(&1, [
            :id,
            :initiator_human_id,
            :recipient_human_id,
            :relationship_mode,
            :status,
            :inserted_at
          ])
        ),
      sent_messages:
        list(Message, where: [sender_human_id: human.id])
        |> Enum.map(
          &take(&1, [
            :id,
            :thread_id,
            :format,
            :encoding,
            :schema_uri,
            :opaque_payload,
            :metadata,
            :inserted_at,
            :deleted_at
          ])
        ),
      inbox:
        list(InboxEvent, where: [human_id: human.id])
        |> Enum.map(
          &take(&1, [:id, :type, :resource_type, :resource_id, :metadata, :inserted_at, :read_at])
        ),
      reports:
        list(Report, where: [reporter_human_id: human.id])
        |> Enum.map(
          &take(&1, [:id, :subject_type, :subject_id, :category, :details, :status, :inserted_at])
        ),
      audit:
        list(AuditEvent, where: [actor_human_id: human.id])
        |> Enum.map(
          &take(&1, [
            :id,
            :event_type,
            :resource_type,
            :resource_id,
            :agent_binding_id,
            :idempotency_key,
            :configuration_version,
            :metadata,
            :inserted_at
          ])
        )
    }
  end

  def revoke_agent(%Human{} = human) do
    now = DateTime.utc_now()

    Repo.update_all(
      from(binding in AgentBinding, where: binding.human_id == ^human.id and binding.active),
      set: [active: false, revoked_at: now]
    )

    audit(human.id, "human.agent_revoked", "human", human.id)
    :ok
  end

  def block(%Human{} = human, target_id, reason) do
    Safety.block_human(human.id, target_id, reason)
  end

  def report(%Human{} = human, target_id, category) do
    Safety.report_human(human.id, %{
      "subject_type" => "human",
      "subject_id" => target_id,
      "category" => category,
      "details" => %{"source" => "human_control_dashboard"}
    })
  end

  def end_connection(%Human{} = human, connection_id) do
    now = DateTime.utc_now()

    {count, _} =
      Repo.update_all(
        from(connection in Connection,
          where:
            connection.id == ^connection_id and connection.status == "active" and
              (connection.human_a_id == ^human.id or connection.human_b_id == ^human.id)
        ),
        set: [status: "ended", updated_at: now]
      )

    if count == 1 do
      audit(human.id, "human.connection_ended", "connection", connection_id)
      :ok
    else
      {:error, :not_found}
    end
  end

  def revoke_grant(%Human{} = human, grant_id) do
    now = DateTime.utc_now()

    {count, _} =
      Repo.update_all(
        from(grant in ContactGrant,
          where:
            grant.id == ^grant_id and grant.owner_human_id == ^human.id and
              is_nil(grant.revoked_at)
        ),
        set: [revoked_at: now, updated_at: now]
      )

    if count == 1 do
      audit(human.id, "human.contact_grant_revoked", "contact_grant", grant_id)
      :ok
    else
      {:error, :not_found}
    end
  end

  def delete_account(%Human{} = human), do: Identity.delete_human(human.id)

  defp audit(human_id, event_type, resource_type, resource_id) do
    AgentSocial.Operations.audit_changeset(%{
      actor_human_id: human_id,
      event_type: event_type,
      resource_type: resource_type,
      resource_id: resource_id,
      metadata: %{actor: "human_control_dashboard"}
    })
    |> Repo.insert()
  end

  defp list(schema, where: filters), do: Repo.all(from item in schema, where: ^filters)
  defp take(nil, _fields), do: nil
  defp take(struct, fields), do: Map.take(struct, fields)
end
