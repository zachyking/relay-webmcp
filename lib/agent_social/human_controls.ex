defmodule AgentSocial.HumanControls do
  @moduledoc "Direct human safety, consent, export, revocation, and deletion controls."

  import Ecto.Query

  alias AgentSocial.Connections.{
    Connection,
    ContactGrant,
    HumanApproval,
    IntroductionProposal,
    Message,
    Thread
  }

  alias AgentSocial.Identity.{AgentBinding, ContactField, Human, Policy, ProfileClaim}
  alias AgentSocial.Operations.{AuditEvent, InboxEvent}
  alias AgentSocial.Safety.{Block, Report}
  alias AgentSocial.Social.ContentEnvelope
  alias AgentSocial.Studio.ReviewSession
  alias AgentSocial.{Identity, RateLimiter, Repo, Safety}

  @token_salt "human-control-v1"

  def token_for(%Human{id: id}, opts \\ []),
    do: Phoenix.Token.sign(AgentSocialWeb.Endpoint, @token_salt, id, opts)

  def token_lifetime_seconds,
    do: Application.get_env(:agent_social, :human_control_token_max_age, 3_600)

  def verify_token(token) do
    max_age = token_lifetime_seconds()

    with {:ok, human_id} <-
           Phoenix.Token.verify(AgentSocialWeb.Endpoint, @token_salt, token, max_age: max_age),
         %Human{} = human <- Repo.get(Human, human_id) do
      {:ok, human}
    else
      nil -> {:error, :not_found}
      _ -> {:error, :invalid_or_expired_token}
    end
  end

  def request_link(email) when is_binary(email) do
    normalized_email = email |> String.trim() |> String.downcase()
    email_hash = :crypto.hash(:sha256, normalized_email)

    case RateLimiter.check(
           "human-control:email:#{Base.url_encode64(email_hash, padding: false)}",
           3,
           3_600
         ) do
      :ok -> deliver_control_link(email_hash)
      {:error, :rate_limited, _retry_after} -> :ok
    end
  end

  def request_link(_email), do: :ok

  defp deliver_control_link(email_hash) do
    case Repo.get_by(Human, email_hash: email_hash, status: "active") do
      %Human{} = human ->
        url = AgentSocialWeb.Endpoint.url() <> "/human/" <> token_for(human)

        AgentSocial.Notifier.human_control_link(human.email, url, %{
          expires_in_minutes: div(token_lifetime_seconds(), 60)
        })

      nil ->
        :ok
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

    approvals =
      Repo.all(
        from approval in HumanApproval,
          where: approval.human_id == ^human.id,
          order_by: [desc: approval.inserted_at],
          limit: 25
      )

    activity =
      Repo.all(
        from event in AuditEvent,
          where: event.actor_human_id == ^human.id,
          order_by: [desc: event.inserted_at],
          limit: 50
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
      approvals: enrich_approvals(approvals, human),
      activity: enrich_activity(activity, human),
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
      studio_review_sessions:
        list(ReviewSession, where: [human_id: human.id])
        |> Enum.map(
          &take(&1, [
            :id,
            :draft,
            :draft_version,
            :review,
            :status,
            :published_content_id,
            :expires_at,
            :last_agent_action_at,
            :last_human_action_at,
            :inserted_at,
            :updated_at
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

  defp enrich_approvals(approvals, human) do
    recipient_ids = approvals |> Enum.map(& &1.recipient_human_id) |> Enum.reject(&is_nil/1)

    recipients =
      Repo.all(from recipient in Human, where: recipient.id in ^recipient_ids)
      |> Map.new(&{&1.id, &1.handle})

    field_ids = approvals |> Enum.flat_map(& &1.fields) |> Enum.uniq()

    fields =
      Repo.all(
        from field in ContactField,
          where: field.id in ^field_ids and field.human_id == ^human.id
      )
      |> Map.new(&{&1.id, &1.kind})

    Enum.map(approvals, fn approval ->
      %{
        approval: approval,
        recipient_handle: Map.get(recipients, approval.recipient_human_id),
        field_labels: Enum.map(approval.fields, &Map.get(fields, &1, "unknown field"))
      }
    end)
  end

  defp enrich_activity(events, human) do
    content =
      owned_records(ContentEnvelope, event_ids(events, "content"), human.id, :author_human_id)

    messages = owned_records(Message, event_ids(events, "message"), human.id, :sender_human_id)
    claims = owned_records(ProfileClaim, event_ids(events, "profile_claim"), human.id, :human_id)

    contacts =
      owned_records(ContactField, event_ids(events, "contact_field"), human.id, :human_id)

    policies = owned_records(Policy, event_ids(events, "policy"), human.id, :human_id)

    studio_sessions =
      owned_records(
        ReviewSession,
        event_ids(events, "studio_review_session"),
        human.id,
        :human_id
      )

    threads =
      Repo.all(
        from thread in Thread,
          where:
            thread.id in ^event_ids(events, "thread") and
              (thread.initiator_human_id == ^human.id or thread.recipient_human_id == ^human.id)
      )
      |> Map.new(&{&1.id, &1})

    introductions =
      Repo.all(
        from proposal in IntroductionProposal,
          where:
            proposal.id in ^event_ids(events, "introduction") and
              (proposal.proposer_human_id == ^human.id or proposal.recipient_human_id == ^human.id)
      )
      |> Map.new(&{&1.id, &1})

    resources = %{
      "content" => content,
      "message" => messages,
      "profile_claim" => claims,
      "contact_field" => contacts,
      "policy" => policies,
      "thread" => threads,
      "introduction" => introductions,
      "studio_review_session" => studio_sessions
    }

    Enum.map(events, fn event ->
      record = resources |> Map.get(event.resource_type, %{}) |> Map.get(event.resource_id)
      %{event: event, detail: resource_detail(event.resource_type, record)}
    end)
  end

  defp event_ids(events, type) do
    events
    |> Enum.filter(&(&1.resource_type == type))
    |> Enum.map(& &1.resource_id)
    |> Enum.reject(&is_nil/1)
  end

  defp owned_records(schema, ids, human_id, owner_field) do
    Repo.all(
      from record in schema,
        where: record.id in ^ids and field(record, ^owner_field) == ^human_id
    )
    |> Map.new(&{&1.id, &1})
  end

  defp resource_detail("content", %ContentEnvelope{} = content) do
    %{
      title: "#{humanize(content.kind)} · #{humanize(content.visibility)}",
      body: content.opaque_payload,
      facts: [
        {"Format", "#{content.format} · #{content.encoding}"},
        {"Relationship modes", Enum.join(content.relationship_modes, ", ")},
        {"Topics", Enum.join(content.topic_ids, ", ")}
      ]
    }
  end

  defp resource_detail("message", %Message{} = message) do
    %{
      title: "Private agent message",
      body: message.opaque_payload,
      facts: [
        {"Thread", message.thread_id},
        {"Format", "#{message.format} · #{message.encoding}"}
      ]
    }
  end

  defp resource_detail("profile_claim", %ProfileClaim{} = claim) do
    %{
      title: "Profile claim · #{claim.key}",
      body: Jason.encode!(claim.value, pretty: true),
      facts: [{"Visibility", claim.visibility}]
    }
  end

  defp resource_detail("contact_field", %ContactField{} = field) do
    %{
      title: "Private contact field · #{field.kind}",
      body: field.value,
      facts: [{"Label", field.label || "None"}]
    }
  end

  defp resource_detail("policy", %Policy{} = policy) do
    %{
      title: "Agent policy · version #{policy.version}",
      body: nil,
      facts: [
        {"Relationship modes", Enum.join(policy.relationship_modes, ", ")},
        {"Inbound threads", yes_no(policy.allow_inbound_threads)},
        {"Daily post limit", policy.daily_post_limit},
        {"Daily message limit", policy.daily_message_limit}
      ]
    }
  end

  defp resource_detail("thread", %Thread{} = thread) do
    %{
      title: "Agent-to-agent thread",
      body: nil,
      facts: [
        {"Relationship mode", humanize(thread.relationship_mode)},
        {"Status", humanize(thread.status)},
        {"Initiator human ID", thread.initiator_human_id},
        {"Recipient human ID", thread.recipient_human_id}
      ]
    }
  end

  defp resource_detail("introduction", %IntroductionProposal{} = proposal) do
    %{
      title: "Introduction proposal",
      body: proposal.purpose,
      facts: [{"Status", humanize(proposal.status)}, {"Thread", proposal.thread_id}]
    }
  end

  defp resource_detail("studio_review_session", %ReviewSession{} = session) do
    %{
      title: "Shared Review Room · draft v#{session.draft_version}",
      body: session.draft["body"],
      facts: [
        {"Status", humanize(session.status)},
        {"Summary", session.draft["summary"]},
        {"Relationship modes", Enum.join(session.draft["relationship_modes"] || [], ", ")},
        {"Review expires", DateTime.to_iso8601(session.expires_at)}
      ]
    }
  end

  defp resource_detail(_type, _record), do: nil

  defp humanize(value) when is_binary(value), do: String.replace(value, "_", " ")
  defp humanize(value), do: to_string(value)
  defp yes_no(true), do: "Allowed"
  defp yes_no(false), do: "Not allowed"

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
