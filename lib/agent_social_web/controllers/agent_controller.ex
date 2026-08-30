defmodule AgentSocialWeb.AgentController do
  use AgentSocialWeb, :controller

  alias AgentSocial.{Connections, Governance, Identity, Operations, Safety, Social, Webhooks}
  alias AgentSocialWeb.JSON

  def profile_get(conn, _params) do
    binding = agent_binding(conn)

    with :ok <- require_scope(binding, "profile:read") do
      json(conn, %{data: Identity.get_profile(binding.human_id, binding.human_id) |> JSON.human()})
    else
      error -> respond_error(conn, error)
    end
  end

  def profile_show(conn, %{"id" => id}) do
    binding = agent_binding(conn)

    with :ok <- require_scope(binding, "profile:read") do
      json(conn, %{data: Identity.get_profile(id, binding.human_id) |> JSON.human()})
    else
      error -> respond_error(conn, error)
    end
  end

  def profile_update(conn, params) do
    binding = agent_binding(conn)

    with {:ok, key} <- authorize_write(conn, "profile:write"),
         {:ok, claim} <- Identity.upsert_profile_claim(binding, params),
         {:ok, _} <-
           audit_mutation(binding, "profile.claim_set", "profile_claim", claim.id, key, %{
             visibility: claim.visibility
           }) do
      json(conn, %{data: JSON.profile_claim(claim)})
    else
      error -> respond_error(conn, error)
    end
  end

  def contact_field_set(conn, params) do
    binding = agent_binding(conn)

    with {:ok, key} <- authorize_write(conn, "profile:write"),
         {:ok, field} <- Identity.upsert_contact_field(binding, params),
         {:ok, _} <-
           audit_mutation(binding, "profile.contact_field_set", "contact_field", field.id, key, %{
             kind: field.kind
           }) do
      json(conn, %{data: Map.take(field, [:id, :kind, :label, :inserted_at, :updated_at])})
    else
      error -> respond_error(conn, error)
    end
  end

  def policy_get(conn, _params) do
    binding = agent_binding(conn)

    with :ok <- require_scope(binding, "profile:read") do
      json(conn, %{data: binding.human_id |> Identity.get_policy() |> JSON.policy()})
    else
      error -> respond_error(conn, error)
    end
  end

  def policy_set(conn, params) do
    binding = agent_binding(conn)

    with {:ok, key} <- authorize_write(conn, "profile:write"),
         {:ok, policy} <- Identity.update_policy(binding, params),
         {:ok, _} <-
           audit_mutation(binding, "policy.updated", "policy", policy.id, key, %{
             version: policy.version
           }) do
      json(conn, %{data: JSON.policy(policy)})
    else
      error -> respond_error(conn, error)
    end
  end

  def feed_browse(conn, params) do
    binding = agent_binding(conn)

    with :ok <- require_scope(binding, "feed:read"),
         {:ok, contents, cursor} <- Social.browse_feed(binding.human_id, cursor_opts(params)) do
      json(conn, %{
        data: Enum.map(contents, &JSON.content/1),
        next_cursor: cursor,
        untrusted_content: true
      })
    else
      error -> respond_error(conn, error)
    end
  end

  def network_search(conn, params) do
    binding = agent_binding(conn)

    with :ok <- require_scope(binding, "feed:read"),
         query when is_binary(query) and byte_size(query) > 0 <- params["q"] do
      limit = integer_param(params["limit"], 30) |> min(100) |> max(1)
      profile_limit = min(limit, 20)
      profiles = Identity.search_profiles(binding.human_id, query, limit: profile_limit)
      content_limit = max(limit - length(profiles), 1)
      contents = Social.search(binding.human_id, query, limit: content_limit)

      results =
        (Enum.map(profiles, &JSON.profile_search_result/1) ++
           Enum.map(contents, &JSON.content_search_result/1))
        |> Enum.take(limit)

      json(conn, %{data: results, untrusted_content: true})
    else
      nil -> respond_error(conn, {:error, :query_required})
      error -> respond_error(conn, error)
    end
  end

  def item_get(conn, %{"id" => id}) do
    binding = agent_binding(conn)

    with :ok <- require_scope(binding, "feed:read"),
         {:ok, content} <- Social.get_item(id, binding.human_id) do
      json(conn, %{data: JSON.content(content), untrusted_content: true})
    else
      error -> respond_error(conn, error)
    end
  end

  def post_publish(conn, params) do
    binding = agent_binding(conn)

    with {:ok, key} <- authorize_write(conn, "content:write"),
         {:ok, content} <- Social.publish(binding, params, key),
         {:ok, content} <- Social.get_item(content.id, binding.human_id) do
      conn |> put_status(:created) |> json(%{data: JSON.content(content)})
    else
      error -> respond_error(conn, error)
    end
  end

  def post_reply(conn, %{"id" => parent_id} = params) do
    binding = agent_binding(conn)

    with {:ok, key} <- authorize_write(conn, "content:write"),
         {:ok, content} <- Social.reply(binding, parent_id, Map.delete(params, "id"), key) do
      conn |> put_status(:created) |> json(%{data: %{id: content.id}})
    else
      error -> respond_error(conn, error)
    end
  end

  def reaction_set(conn, %{"id" => content_id, "kind" => kind}) do
    binding = agent_binding(conn)

    with {:ok, key} <- authorize_write(conn, "content:write"),
         {:ok, reaction} <- Social.set_reaction(binding, content_id, kind),
         {:ok, _} <-
           audit_mutation(binding, "content.reaction_set", "content", content_id, key, %{
             reaction: reaction.kind
           }) do
      json(conn, %{data: Map.take(reaction, [:id, :content_id, :human_id, :kind])})
    else
      error -> respond_error(conn, error)
    end
  end

  def community_create(conn, params) do
    binding = agent_binding(conn)

    with {:ok, key} <- authorize_write(conn, "community:write"),
         {:ok, community} <- Social.create_community(binding, params, key) do
      conn |> put_status(:created) |> json(%{data: JSON.community(community)})
    else
      error -> respond_error(conn, error)
    end
  end

  def community_join(conn, %{"id" => id}) do
    binding = agent_binding(conn)

    with {:ok, key} <- authorize_write(conn, "community:write"),
         {:ok, membership} <- Social.join_community(binding, id, key) do
      json(conn, %{data: Map.take(membership, [:id, :community_id, :human_id, :role, :status])})
    else
      error -> respond_error(conn, error)
    end
  end

  def community_rules_set(conn, %{"id" => id, "rules" => _rules} = params) do
    binding = agent_binding(conn)

    with {:ok, key} <- authorize_write(conn, "community:write"),
         {:ok, rule} <- Social.set_community_rules(binding, id, Map.delete(params, "id"), key) do
      json(conn, %{data: Map.take(rule, [:id, :community_id, :version, :rules, :inserted_at])})
    else
      error -> respond_error(conn, error)
    end
  end

  def community_moderate(conn, %{"id" => id} = params) do
    binding = agent_binding(conn)

    with {:ok, key} <- authorize_write(conn, "community:write"),
         {:ok, action} <-
           Social.moderate_community(binding, id, Map.delete(params, "id"), key) do
      json(conn, %{
        data:
          Map.take(action, [
            :id,
            :community_id,
            :moderator_human_id,
            :subject_type,
            :subject_id,
            :action,
            :reason,
            :inserted_at
          ])
      })
    else
      error -> respond_error(conn, error)
    end
  end

  def thread_open(conn, %{
        "recipient_human_id" => recipient_id,
        "relationship_mode" => relationship_mode
      }) do
    binding = agent_binding(conn)

    with {:ok, key} <- authorize_write(conn, "thread:write"),
         {:ok, thread} <- Connections.open_thread(binding, recipient_id, relationship_mode, key) do
      conn |> put_status(:created) |> json(%{data: JSON.thread(thread)})
    else
      error -> respond_error(conn, error)
    end
  end

  def thread_send(conn, %{"id" => thread_id} = params) do
    binding = agent_binding(conn)

    with {:ok, key} <- authorize_write(conn, "thread:write"),
         {:ok, message} <-
           Connections.send_message(binding, thread_id, Map.delete(params, "id"), key) do
      conn |> put_status(:created) |> json(%{data: JSON.message(message)})
    else
      error -> respond_error(conn, error)
    end
  end

  def thread_messages(conn, %{"id" => thread_id} = params) do
    binding = agent_binding(conn)

    with :ok <- require_scope(binding, "thread:write"),
         {:ok, messages} <- Connections.list_messages(binding, thread_id, after_opts(params)) do
      json(conn, %{data: Enum.map(messages, &JSON.message/1), untrusted_content: true})
    else
      error -> respond_error(conn, error)
    end
  end

  def intro_propose(conn, %{"thread_id" => thread_id, "purpose" => purpose}) do
    binding = agent_binding(conn)

    with {:ok, key} <- authorize_write(conn, "connection:write"),
         {:ok, result} <- Connections.propose_introduction(binding, thread_id, purpose, key) do
      data = %{proposal: JSON.proposal(result.proposal)}

      data =
        if result[:development_approval_tokens],
          do: Map.put(data, :development_approval_tokens, result.development_approval_tokens),
          else: data

      conn |> put_status(:created) |> json(%{data: data})
    else
      error -> respond_error(conn, error)
    end
  end

  def intro_respond(conn, %{"id" => id, "response" => response}) do
    binding = agent_binding(conn)

    with {:ok, key} <- authorize_write(conn, "connection:write"),
         {:ok, proposal} <- Connections.respond_to_introduction(binding, id, response),
         {:ok, _} <-
           audit_mutation(binding, "introduction.responded", "introduction", proposal.id, key, %{
             status: proposal.status
           }) do
      json(conn, %{data: JSON.proposal(proposal)})
    else
      error -> respond_error(conn, error)
    end
  end

  def contact_request(
        conn,
        %{
          "connection_id" => connection_id,
          "field_kinds" => field_kinds,
          "purpose" => purpose
        } = params
      ) do
    binding = agent_binding(conn)
    expiry_days = Map.get(params, "expiry_days", 30)

    with {:ok, key} <- authorize_write(conn, "connection:write"),
         {:ok, result} <-
           Connections.request_contact_release(
             binding,
             connection_id,
             field_kinds,
             purpose,
             expiry_days,
             key
           ) do
      data = %{approval: JSON.approval(result.approval)}

      data =
        if result[:development_approval_token],
          do: Map.put(data, :development_approval_token, result.development_approval_token),
          else: data

      conn |> put_status(:created) |> json(%{data: data})
    else
      error -> respond_error(conn, error)
    end
  end

  def contact_get(conn, %{"connection_id" => connection_id}) do
    binding = agent_binding(conn)

    with :ok <- require_scope(binding, "connection:write"),
         {:ok, contacts} <- Connections.get_released_contacts(binding, connection_id) do
      json(conn, %{data: Enum.map(contacts, &JSON.contact/1)})
    else
      error -> respond_error(conn, error)
    end
  end

  def connection_checkin(conn, %{"id" => id} = params) do
    binding = agent_binding(conn)

    with {:ok, key} <- authorize_write(conn, "connection:write"),
         {:ok, checkin} <- Connections.submit_checkin(binding, id, Map.delete(params, "id")),
         {:ok, _} <-
           audit_mutation(
             binding,
             "connection.checkin_submitted",
             "connection_checkin",
             checkin.id,
             key,
             %{
               active: checkin.active,
               useful: checkin.useful
             }
           ) do
      json(conn, %{
        data:
          Map.take(checkin, [:id, :connection_id, :period_days, :active, :useful, :responded_at])
      })
    else
      error -> respond_error(conn, error)
    end
  end

  def inbox_read(conn, params) do
    binding = agent_binding(conn)

    with :ok <- require_scope(binding, "feed:read") do
      events = Operations.list_inbox(binding.human_id, after_opts(params))

      json(conn, %{
        data: Enum.map(events, &JSON.inbox/1),
        next_cursor: events |> List.last() |> then(&if(&1, do: &1.id, else: nil))
      })
    else
      error -> respond_error(conn, error)
    end
  end

  def governance_propose(conn, params) do
    binding = agent_binding(conn)

    with {:ok, key} <- authorize_write(conn, "governance:write"),
         {:ok, proposal} <- Governance.propose(binding, params),
         {:ok, _} <-
           audit_mutation(
             binding,
             "governance.proposed",
             "governance_proposal",
             proposal.id,
             key,
             %{
               status: proposal.status
             }
           ) do
      conn
      |> put_status(:created)
      |> json(%{
        data: Map.take(proposal, [:id, :kind, :title, :changes, :status, :voting_ends_at])
      })
    else
      error -> respond_error(conn, error)
    end
  end

  def webhook_set(conn, params) do
    binding = agent_binding(conn)

    with {:ok, key} <- authorize_write(conn, "webhook:write"),
         {:ok, subscription, secret} <- Webhooks.set(binding, params),
         {:ok, _} <-
           audit_mutation(
             binding,
             "webhook.configured",
             "webhook_subscription",
             subscription.id,
             key,
             %{
               active: subscription.active
             }
           ) do
      json(conn, %{
        data: %{
          id: subscription.id,
          url: subscription.url,
          event_types: subscription.event_types,
          active: subscription.active,
          signing_secret: secret
        }
      })
    else
      error -> respond_error(conn, error)
    end
  end

  def governance_vote(conn, %{"id" => id, "choice" => choice}) do
    binding = agent_binding(conn)

    with {:ok, key} <- authorize_write(conn, "governance:write"),
         {:ok, vote} <- Governance.vote(binding, id, choice),
         {:ok, _} <-
           audit_mutation(binding, "governance.voted", "governance_vote", vote.id, key, %{
             choice: vote.choice
           }) do
      json(conn, %{
        data: %{
          id: vote.id,
          proposal_id: vote.proposal_id,
          choice: vote.choice,
          weight: Decimal.to_float(vote.weight),
          reputation_snapshot: Decimal.to_float(vote.reputation_snapshot)
        }
      })
    else
      error -> respond_error(conn, error)
    end
  end

  def block(conn, %{"blocked_human_id" => id} = params) do
    binding = agent_binding(conn)

    with {:ok, key} <- authorize_write(conn, "profile:write"),
         {:ok, block} <- Safety.block(binding, id, params["reason"]),
         {:ok, _} <-
           audit_mutation(binding, "safety.blocked", "human", block.blocked_human_id, key, %{}) do
      json(conn, %{data: Map.take(block, [:id, :blocked_human_id, :reason, :inserted_at])})
    else
      error -> respond_error(conn, error)
    end
  end

  def report(conn, params) do
    binding = agent_binding(conn)

    with {:ok, key} <- authorize_write(conn, "profile:write"),
         {:ok, report} <- Safety.report(binding, params),
         {:ok, _} <-
           audit_mutation(
             binding,
             "safety.reported",
             report.subject_type,
             report.subject_id,
             key,
             %{
               category: report.category,
               status: report.status
             }
           ) do
      conn
      |> put_status(:created)
      |> json(%{data: Map.take(report, [:id, :subject_type, :subject_id, :category, :status])})
    else
      error -> respond_error(conn, error)
    end
  end

  def revoke(conn, _params) do
    binding = agent_binding(conn)

    with {:ok, key} <- authorize_write(conn, "profile:write"),
         {:ok, revoked_binding} <- Identity.revoke_binding(binding),
         {:ok, _} <-
           audit_mutation(
             binding,
             "identity.agent_revoked",
             "agent_binding",
             revoked_binding.id,
             key,
             %{
               active: false
             }
           ) do
      json(conn, %{data: %{revoked: true}})
    else
      error -> respond_error(conn, error)
    end
  end

  def delete_account(conn, _params) do
    binding = agent_binding(conn)

    with {:ok, key} <- authorize_write(conn, "profile:write"),
         {:ok, _} <- Identity.delete_account(binding),
         {:ok, _} <-
           audit_mutation(
             binding,
             "identity.deletion_requested",
             "human",
             binding.human_id,
             key,
             %{
               status: "deleting"
             }
           ) do
      json(conn, %{data: %{deletion_started: true, purge_within_days: 30}})
    else
      error -> respond_error(conn, error)
    end
  end

  defp agent_binding(conn), do: conn.assigns.agent_binding

  defp audit_mutation(binding, event, type, id, key, result_state) do
    Operations.record_agent_audit(binding, event, type, id, key, result_state)
  end

  defp authorize_write(conn, scope) do
    with :ok <- require_scope(agent_binding(conn), scope) do
      case conn.assigns[:idempotency_key] do
        key when is_binary(key) -> {:ok, key}
        _ -> {:error, :idempotency_key_required}
      end
    end
  end

  defp require_scope(binding, scope) do
    if scope in binding.scopes, do: :ok, else: {:error, :insufficient_scope}
  end

  defp cursor_opts(params),
    do: [cursor: params["cursor"], limit: integer_param(params["limit"], 30)]

  defp after_opts(params), do: [after: params["after"], limit: integer_param(params["limit"], 50)]

  defp integer_param(value, default) when is_binary(value) do
    case Integer.parse(value),
      do: (
        {number, ""} -> number
        _ -> default
      )
  end

  defp integer_param(value, _default) when is_integer(value), do: value
  defp integer_param(_, default), do: default

  defp respond_error(conn, {:error, reason}), do: render_error(conn, reason)
  defp respond_error(conn, reason), do: render_error(conn, reason)

  defp render_error(conn, reason) do
    {status, code} =
      case reason do
        :not_found -> {:not_found, "not_found"}
        :not_permitted -> {:forbidden, "not_permitted"}
        :insufficient_scope -> {:forbidden, "insufficient_scope"}
        :blocked -> {:forbidden, "blocked"}
        :idempotency_key_required -> {:bad_request, "idempotency_key_required"}
        :duplicate_idempotency_key -> {:conflict, "duplicate_idempotency_key"}
        :daily_post_limit -> {:too_many_requests, "daily_post_limit"}
        :daily_message_limit -> {:too_many_requests, "daily_message_limit"}
        _ -> {:unprocessable_entity, "invalid_request"}
      end

    conn |> put_status(status) |> json(%{error: %{code: code}})
  end
end
