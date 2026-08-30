defmodule AgentSocial.Operations do
  @moduledoc "Transactional audit, outbox, and durable inbox helpers."

  import Ecto.Query
  alias AgentSocial.Repo
  alias AgentSocial.Governance.ConfigurationVersion
  alias AgentSocial.Identity.{AgentBinding, Policy}
  alias AgentSocial.Operations.{AuditEvent, InboxEvent, OutboxEvent}

  def audit_changeset(attrs), do: AuditEvent.changeset(%AuditEvent{}, attrs)
  def outbox_changeset(attrs), do: OutboxEvent.changeset(%OutboxEvent{}, attrs)
  def inbox_changeset(attrs), do: InboxEvent.changeset(%InboxEvent{}, attrs)

  def agent_audit_attrs(
        %AgentBinding{} = binding,
        event_type,
        resource_type,
        resource_id,
        idempotency_key,
        result_state \\ %{}
      ) do
    policy_version =
      Repo.one(
        from policy in Policy,
          where: policy.human_id == ^binding.human_id,
          select: policy.version
      )

    configuration_version =
      Repo.one(
        from configuration in ConfigurationVersion,
          where: configuration.status == "active",
          select: configuration.version,
          limit: 1
      ) || 1

    %{
      actor_human_id: binding.human_id,
      agent_binding_id: binding.id,
      agent_key_version: binding.key_version,
      client_id: binding.client_id || binding.client_name,
      policy_version: policy_version,
      configuration_version: configuration_version,
      event_type: event_type,
      resource_type: resource_type,
      resource_id: resource_id,
      idempotency_key: idempotency_key,
      result_state: result_state
    }
  end

  def record_agent_audit(
        binding,
        event_type,
        resource_type,
        resource_id,
        key,
        result_state \\ %{}
      ) do
    binding
    |> agent_audit_attrs(event_type, resource_type, resource_id, key, result_state)
    |> audit_changeset()
    |> Repo.insert()
  end

  def list_inbox(human_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 50) |> min(100) |> max(1)
    after_id = Keyword.get(opts, :after)

    query =
      from event in InboxEvent,
        where: event.human_id == ^human_id,
        order_by: [asc: event.inserted_at, asc: event.id],
        limit: ^limit

    query = if after_id, do: from(event in query, where: event.id > ^after_id), else: query
    Repo.all(query)
  end
end
