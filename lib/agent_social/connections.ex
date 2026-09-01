defmodule AgentSocial.Connections do
  @moduledoc "Agent-mediated threads, introductions, human approval, contact grants, and retention."

  import Ecto.Query
  alias Ecto.Multi
  alias AgentSocial.{Operations, Repo}
  alias AgentSocial.Identity.{AgentBinding, ContactField, Human, Policy}

  alias AgentSocial.Connections.{
    Connection,
    ConnectionCheckin,
    ContactGrant,
    HumanApproval,
    IntroductionProposal,
    Message,
    Thread
  }

  def open_thread(
        %AgentBinding{} = binding,
        recipient_id,
        relationship_mode,
        idempotency_key \\ nil
      ) do
    with {:ok, recipient_id} <- Ecto.UUID.cast(recipient_id),
         :ok <- allow_thread?(binding.human_id, recipient_id),
         true <- relationship_mode in AgentSocial.Types.relationship_modes() do
      existing =
        Repo.one(
          from thread in Thread,
            where:
              thread.relationship_mode == ^relationship_mode and
                ((thread.initiator_human_id == ^binding.human_id and
                    thread.recipient_human_id == ^recipient_id) or
                   (thread.initiator_human_id == ^recipient_id and
                      thread.recipient_human_id == ^binding.human_id))
        )

      if existing do
        {:ok, existing}
      else
        Multi.new()
        |> Multi.insert(
          :thread,
          Thread.changeset(%Thread{}, %{
            initiator_human_id: binding.human_id,
            recipient_human_id: recipient_id,
            relationship_mode: relationship_mode
          })
        )
        |> Multi.insert(:inbox, fn %{thread: thread} ->
          Operations.inbox_changeset(%{
            human_id: recipient_id,
            type: "thread.opened",
            resource_type: "thread",
            resource_id: thread.id
          })
        end)
        |> Multi.insert(:audit, fn %{thread: thread} ->
          Operations.audit_changeset(
            audit_attrs(binding, "thread.opened", "thread", thread.id, idempotency_key)
          )
        end)
        |> Repo.transaction()
        |> unwrap(:thread)
      end
    else
      :error -> {:error, :invalid_recipient}
      false -> {:error, :invalid_relationship_mode}
      error -> error
    end
  end

  def send_message(%AgentBinding{} = binding, thread_id, attrs, idempotency_key \\ nil) do
    attrs = normalize_payload(attrs)

    with %Thread{status: "active"} = thread <- Repo.get(Thread, thread_id),
         :ok <- participant?(thread, binding.human_id),
         :ok <- enforce_message_limit(binding.human_id) do
      recipient_id = other_participant(thread, binding.human_id)
      now = DateTime.utc_now()

      Multi.new()
      |> Multi.insert(:message, fn _ ->
        %Message{
          thread_id: thread.id,
          sender_human_id: binding.human_id,
          agent_binding_id: binding.id
        }
        |> Message.changeset(attrs)
      end)
      |> Multi.update_all(:touch_thread, from(t in Thread, where: t.id == ^thread.id),
        set: [last_message_at: now]
      )
      |> Multi.insert(:inbox, fn %{message: message} ->
        Operations.inbox_changeset(%{
          human_id: recipient_id,
          type: "thread.message",
          resource_type: "message",
          resource_id: message.id,
          metadata: %{thread_id: thread.id}
        })
      end)
      |> Multi.insert(:audit, fn %{message: message} ->
        Operations.audit_changeset(
          audit_attrs(binding, "message.sent", "message", message.id, idempotency_key)
        )
      end)
      |> Repo.transaction()
      |> unwrap(:message)
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def list_messages(%AgentBinding{} = binding, thread_id, opts \\ []) do
    with %Thread{} = thread <- Repo.get(Thread, thread_id),
         :ok <- participant?(thread, binding.human_id) do
      limit = opts |> Keyword.get(:limit, 50) |> min(100) |> max(1)
      cursor = Keyword.get(opts, :after)

      query =
        from message in Message,
          where: message.thread_id == ^thread.id and is_nil(message.deleted_at),
          order_by: [asc: message.inserted_at, asc: message.id],
          limit: ^limit

      query = if cursor, do: from(m in query, where: m.id > ^cursor), else: query
      {:ok, Repo.all(query)}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def propose_introduction(%AgentBinding{} = binding, thread_id, purpose, idempotency_key \\ nil) do
    with %Thread{status: "active"} = thread <- Repo.get(Thread, thread_id),
         :ok <- participant?(thread, binding.human_id) do
      recipient_id = other_participant(thread, binding.human_id)
      expires_at = DateTime.add(DateTime.utc_now(), 7, :day)
      proposer_token = approval_token()
      recipient_token = approval_token()

      transaction =
        Multi.new()
        |> Multi.insert(
          :proposal,
          IntroductionProposal.changeset(%IntroductionProposal{}, %{
            thread_id: thread.id,
            proposer_human_id: binding.human_id,
            recipient_human_id: recipient_id,
            purpose: purpose,
            expires_at: expires_at
          })
        )
        |> Multi.insert(:proposer_approval, fn %{proposal: proposal} ->
          approval_changeset(
            binding.human_id,
            recipient_id,
            "introduction",
            proposal.id,
            proposal.purpose,
            proposer_token,
            expires_at
          )
        end)
        |> Multi.insert(:recipient_approval, fn %{proposal: proposal} ->
          approval_changeset(
            recipient_id,
            binding.human_id,
            "introduction",
            proposal.id,
            proposal.purpose,
            recipient_token,
            expires_at
          )
        end)
        |> Multi.insert(:recipient_inbox, fn %{proposal: proposal} ->
          Operations.inbox_changeset(%{
            human_id: recipient_id,
            type: "introduction.proposed",
            resource_type: "introduction",
            resource_id: proposal.id
          })
        end)
        |> Multi.insert(:audit, fn %{proposal: proposal} ->
          Operations.audit_changeset(
            audit_attrs(
              binding,
              "introduction.proposed",
              "introduction",
              proposal.id,
              idempotency_key
            )
          )
        end)
        |> Repo.transaction()

      case transaction do
        {:ok, %{proposal: proposal}} ->
          notify_approval(binding.human_id, proposer_token, "introduction")
          notify_approval(recipient_id, recipient_token, "introduction")

          response = %{proposal: proposal}

          response =
            if reveal_approvals?() do
              Map.put(response, :development_approval_tokens, %{
                proposer: proposer_token,
                recipient: recipient_token
              })
            else
              response
            end

          {:ok, response}

        {:error, step, reason, _} ->
          {:error, {step, reason}}
      end
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def respond_to_introduction(%AgentBinding{} = binding, proposal_id, "withdraw") do
    case Repo.get(IntroductionProposal, proposal_id) do
      %IntroductionProposal{proposer_human_id: human_id, status: "pending"} = proposal
      when human_id == binding.human_id ->
        proposal |> IntroductionProposal.changeset(%{status: "withdrawn"}) |> Repo.update()

      _ ->
        {:error, :not_permitted}
    end
  end

  def respond_to_introduction(%AgentBinding{} = binding, proposal_id, "decline") do
    case Repo.get(IntroductionProposal, proposal_id) do
      %IntroductionProposal{recipient_human_id: human_id, status: "pending"} = proposal
      when human_id == binding.human_id ->
        proposal |> IntroductionProposal.changeset(%{status: "declined"}) |> Repo.update()

      _ ->
        {:error, :not_permitted}
    end
  end

  def respond_to_introduction(_, _, _), do: {:error, :invalid_response}

  def get_approval(token) do
    case Repo.get_by(HumanApproval, token_digest: digest(token)) do
      nil -> {:error, :not_found}
      approval -> {:ok, approval, Repo.get(Human, approval.human_id), approval_context(approval)}
    end
  end

  def decide_approval(token, decision) when decision in ["approved", "declined"] do
    Multi.new()
    |> Multi.run(:approval, fn repo, _ ->
      approval =
        repo.one(
          from a in HumanApproval, where: a.token_digest == ^digest(token), lock: "FOR UPDATE"
        )

      cond do
        is_nil(approval) -> {:error, :not_found}
        approval.status != "pending" -> {:error, :already_decided}
        DateTime.before?(approval.expires_at, DateTime.utc_now()) -> {:error, :expired}
        true -> {:ok, approval}
      end
    end)
    |> Multi.update(:decided, fn %{approval: approval} ->
      HumanApproval.changeset(approval, %{status: decision, decided_at: DateTime.utc_now()})
    end)
    |> Multi.run(:effect, &apply_approval_effect/2)
    |> Repo.transaction()
    |> case do
      {:ok, %{decided: approval, effect: effect}} -> {:ok, approval, effect}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  def request_contact_release(
        %AgentBinding{} = binding,
        connection_id,
        field_kinds,
        purpose,
        expiry_days,
        idempotency_key \\ nil
      ) do
    with %Connection{status: "active"} = connection <- Repo.get(Connection, connection_id),
         :ok <- connection_participant?(connection, binding.human_id),
         :ok <- valid_contact_request?(purpose, expiry_days),
         owner_id <- connection_other(connection, binding.human_id),
         fields when fields != [] <-
           Repo.all(
             from field in ContactField,
               where: field.human_id == ^owner_id and field.kind in ^field_kinds
           ) do
      token = approval_token()
      expires_at = DateTime.add(DateTime.utc_now(), 7, :day)
      grant_expires_at = DateTime.add(DateTime.utc_now(), expiry_days, :day)
      field_ids = Enum.map(fields, & &1.id)

      approval =
        %HumanApproval{}
        |> HumanApproval.changeset(%{
          human_id: owner_id,
          action: "release_contact",
          resource_type: "contact_release",
          resource_id: connection.id,
          recipient_human_id: binding.human_id,
          fields: field_ids,
          purpose: purpose,
          grant_expires_at: grant_expires_at,
          token_digest: digest(token),
          expires_at: expires_at
        })

      case Repo.insert(approval) do
        {:ok, approval} ->
          _ =
            Operations.audit_changeset(
              audit_attrs(
                binding,
                "contact.requested",
                "connection",
                connection.id,
                idempotency_key
              )
            )
            |> Repo.insert()

          notify_approval(owner_id, token, "contact release")
          response = %{approval: approval}

          response =
            if reveal_approvals?(),
              do: Map.put(response, :development_approval_token, token),
              else: response

          {:ok, response}

        error ->
          error
      end
    else
      nil -> {:error, :not_found}
      [] -> {:error, :contact_fields_not_found}
      error -> error
    end
  end

  def get_released_contacts(%AgentBinding{} = binding, connection_id) do
    now = DateTime.utc_now()

    grants =
      Repo.all(
        from grant in ContactGrant,
          where:
            grant.connection_id == ^connection_id and
              grant.recipient_human_id == ^binding.human_id and
              is_nil(grant.revoked_at) and grant.expires_at > ^now
      )

    field_ids = Enum.flat_map(grants, & &1.field_ids)

    grant_by_field =
      for grant <- grants, field_id <- grant.field_ids, into: %{}, do: {field_id, grant}

    contacts =
      Repo.all(from field in ContactField, where: field.id in ^field_ids)
      |> Enum.map(fn field ->
        grant = Map.fetch!(grant_by_field, field.id)

        %{
          owner_human_id: field.human_id,
          kind: field.kind,
          label: field.label,
          value: field.value,
          purpose: grant.purpose,
          expires_at: grant.expires_at
        }
      end)

    {:ok, contacts}
  end

  def submit_checkin(%AgentBinding{} = binding, checkin_id, attrs) do
    case Repo.get(ConnectionCheckin, checkin_id) do
      %ConnectionCheckin{human_id: human_id, responded_at: nil} = checkin
      when human_id == binding.human_id ->
        if DateTime.compare(checkin.due_at, DateTime.utc_now()) == :gt do
          {:error, :checkin_not_due}
        else
          submit_due_checkin(checkin, binding, attrs)
        end

      %ConnectionCheckin{human_id: human_id} when human_id == binding.human_id ->
        {:error, :already_responded}

      _ ->
        {:error, :not_found}
    end
  end

  defp submit_due_checkin(checkin, binding, attrs) do
    if is_boolean(attrs["active"]) and is_boolean(attrs["useful"]) do
      result =
        checkin
        |> ConnectionCheckin.changeset(%{
          active: attrs["active"],
          useful: attrs["useful"],
          feedback: Map.get(attrs, "feedback", %{}),
          responded_at: DateTime.utc_now()
        })
        |> Repo.update()

      if match?({:ok, _}, result) do
        _ = AgentSocial.Reputation.RecalculationWorker.enqueue(binding.human_id)
      end

      result
    else
      {:error, :invalid_checkin}
    end
  end

  defp apply_approval_effect(repo, %{approval: approval, decided: decided}) do
    case {approval.resource_type, decided.status} do
      {"introduction", "declined"} ->
        repo.update_all(from(p in IntroductionProposal, where: p.id == ^approval.resource_id),
          set: [status: "declined"]
        )

        {:ok, :declined}

      {"introduction", "approved"} ->
        maybe_activate_connection(repo, approval.resource_id)

      {"contact_release", "approved"} ->
        grant =
          %ContactGrant{}
          |> ContactGrant.changeset(%{
            owner_human_id: approval.human_id,
            recipient_human_id: approval.recipient_human_id,
            connection_id: approval.resource_id,
            field_ids: approval.fields,
            purpose: approval.purpose,
            expires_at: approval.grant_expires_at
          })

        repo.insert(grant)

      _ ->
        {:ok, :recorded}
    end
  end

  defp maybe_activate_connection(repo, introduction_id) do
    approved_count =
      repo.aggregate(
        from(a in HumanApproval,
          where:
            a.resource_type == "introduction" and a.resource_id == ^introduction_id and
              a.status == "approved"
        ),
        :count
      )

    if approved_count == 2 do
      proposal = repo.get!(IntroductionProposal, introduction_id)
      thread = repo.get!(Thread, proposal.thread_id)
      now = DateTime.utc_now()

      connection_changeset =
        Connection.changeset(%Connection{}, %{
          introduction_id: proposal.id,
          human_a_id: proposal.proposer_human_id,
          human_b_id: proposal.recipient_human_id,
          relationship_mode: thread.relationship_mode,
          activated_at: now
        })

      with {:ok, connection} <- repo.insert(connection_changeset),
           {_count, nil} <-
             repo.update_all(from(p in IntroductionProposal, where: p.id == ^proposal.id),
               set: [status: "approved"]
             ),
           :ok <- create_checkins(repo, connection, now) do
        {:ok, connection}
      end
    else
      {:ok, :awaiting_other_human}
    end
  end

  defp create_checkins(repo, connection, now) do
    for human_id <- [connection.human_a_id, connection.human_b_id], days <- [30, 90] do
      due_at = DateTime.add(now, days, :day)

      checkin =
        %ConnectionCheckin{}
        |> ConnectionCheckin.changeset(%{
          connection_id: connection.id,
          human_id: human_id,
          period_days: days,
          due_at: due_at
        })
        |> repo.insert!()

      %{checkin_id: checkin.id}
      |> AgentSocial.Connections.CheckinWorker.new(scheduled_at: due_at)
      |> Oban.insert!()
    end

    :ok
  end

  defp approval_changeset(human_id, recipient_id, type, resource_id, purpose, token, expires_at) do
    HumanApproval.changeset(%HumanApproval{}, %{
      human_id: human_id,
      action: "approve_#{type}",
      resource_type: type,
      resource_id: resource_id,
      recipient_human_id: recipient_id,
      purpose: purpose,
      token_digest: digest(token),
      expires_at: expires_at
    })
  end

  defp approval_context(%HumanApproval{resource_type: "introduction"} = approval) do
    %{
      proposal: Repo.get(IntroductionProposal, approval.resource_id),
      recipient: Repo.get(Human, approval.recipient_human_id),
      fields: []
    }
  end

  defp approval_context(%HumanApproval{resource_type: "contact_release"} = approval) do
    %{
      connection: Repo.get(Connection, approval.resource_id),
      recipient: Repo.get(Human, approval.recipient_human_id),
      fields: Repo.all(from field in ContactField, where: field.id in ^approval.fields)
    }
  end

  defp approval_context(_), do: nil

  defp valid_contact_request?(purpose, expiry_days)
       when is_binary(purpose) and byte_size(purpose) in 1..1_000 and
              is_integer(expiry_days) and expiry_days in 1..90,
       do: :ok

  defp valid_contact_request?(_, _), do: {:error, :invalid_contact_request}

  defp notify_approval(human_id, token, action) do
    human = Repo.get!(Human, human_id)
    url = AgentSocialWeb.Endpoint.url() <> "/approvals/" <> token
    AgentSocial.Notifier.approval_link(human.email, action, url)
  end

  defp allow_thread?(sender_id, recipient_id) do
    blocked? =
      Repo.exists?(
        from block in "blocks",
          where:
            (field(block, :blocker_human_id) == type(^sender_id, Ecto.UUID) and
               field(block, :blocked_human_id) == type(^recipient_id, Ecto.UUID)) or
              (field(block, :blocker_human_id) == type(^recipient_id, Ecto.UUID) and
                 field(block, :blocked_human_id) == type(^sender_id, Ecto.UUID))
      )

    recipient_policy = Repo.get_by(Policy, human_id: recipient_id)

    cond do
      sender_id == recipient_id -> {:error, :self_thread}
      blocked? -> {:error, :blocked}
      is_nil(recipient_policy) -> {:error, :recipient_not_found}
      not recipient_policy.allow_inbound_threads -> {:error, :inbound_threads_disabled}
      true -> :ok
    end
  end

  defp participant?(thread, human_id) do
    if human_id in [thread.initiator_human_id, thread.recipient_human_id],
      do: :ok,
      else: {:error, :not_permitted}
  end

  defp connection_participant?(connection, human_id) do
    if human_id in [connection.human_a_id, connection.human_b_id],
      do: :ok,
      else: {:error, :not_permitted}
  end

  defp other_participant(thread, human_id),
    do:
      if(thread.initiator_human_id == human_id,
        do: thread.recipient_human_id,
        else: thread.initiator_human_id
      )

  defp connection_other(connection, human_id),
    do:
      if(connection.human_a_id == human_id,
        do: connection.human_b_id,
        else: connection.human_a_id
      )

  defp normalize_payload(%{"opaque_payload" => payload} = attrs) when is_map(payload) do
    attrs
    |> Map.put("opaque_payload", Jason.encode!(payload))
    |> Map.put("format", "application/json")
  end

  defp normalize_payload(attrs), do: attrs

  defp enforce_message_limit(human_id) do
    policy = Repo.get_by!(Policy, human_id: human_id)
    since = DateTime.add(DateTime.utc_now(), -1, :day)

    count =
      Repo.aggregate(
        from(m in Message, where: m.sender_human_id == ^human_id and m.inserted_at >= ^since),
        :count
      )

    if count < policy.daily_message_limit, do: :ok, else: {:error, :daily_message_limit}
  end

  defp audit_attrs(binding, event, type, id, key) do
    Operations.agent_audit_attrs(binding, event, type, id, key)
  end

  defp unwrap({:ok, result}, key), do: {:ok, Map.fetch!(result, key)}
  defp unwrap({:error, step, reason, _}, _key), do: {:error, {step, reason}}

  defp approval_token,
    do: "apr_" <> (:crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false))

  defp digest(value), do: :crypto.hash(:sha256, value)

  defp reveal_approvals?,
    do: Application.get_env(:agent_social, :reveal_approval_tokens, false)
end
