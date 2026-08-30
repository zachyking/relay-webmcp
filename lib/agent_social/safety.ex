defmodule AgentSocial.Safety do
  @moduledoc "Non-configurable safety floor: blocks, reports, and immediate interaction isolation."

  import Ecto.Query
  alias AgentSocial.{Operations, Repo}
  alias AgentSocial.Identity.AgentBinding
  alias AgentSocial.Safety.{Block, Report}

  def block(%AgentBinding{} = binding, blocked_human_id, reason \\ nil) do
    block_human(binding.human_id, blocked_human_id, reason)
  end

  def block_human(blocker_human_id, blocked_human_id, reason \\ nil) do
    with {:ok, blocked_id} <- Ecto.UUID.cast(blocked_human_id),
         false <- blocked_id == blocker_human_id do
      %Block{}
      |> Block.changeset(%{
        blocker_human_id: blocker_human_id,
        blocked_human_id: blocked_id,
        reason: reason
      })
      |> Repo.insert(
        on_conflict: :nothing,
        conflict_target: [:blocker_human_id, :blocked_human_id]
      )
      |> case do
        {:ok, block} ->
          now = DateTime.utc_now()

          Repo.update_all(
            from(t in "threads",
              where:
                (field(t, :initiator_human_id) == type(^blocker_human_id, Ecto.UUID) and
                   field(t, :recipient_human_id) == type(^blocked_id, Ecto.UUID)) or
                  (field(t, :initiator_human_id) == type(^blocked_id, Ecto.UUID) and
                     field(t, :recipient_human_id) == type(^blocker_human_id, Ecto.UUID))
            ),
            set: [status: "blocked", updated_at: now]
          )

          {:ok, block}

        error ->
          error
      end
    else
      :error -> {:error, :invalid_human_id}
      true -> {:error, :cannot_block_self}
    end
  end

  def report(%AgentBinding{} = binding, attrs) do
    report_human(binding.human_id, attrs, binding.id)
  end

  def report_human(reporter_human_id, attrs, agent_binding_id \\ nil) do
    %Report{}
    |> Report.changeset(Map.put(attrs, "reporter_human_id", reporter_human_id))
    |> Repo.insert()
    |> case do
      {:ok, report} ->
        _ =
          Operations.audit_changeset(%{
            actor_human_id: reporter_human_id,
            agent_binding_id: agent_binding_id,
            event_type: "safety.reported",
            resource_type: report.subject_type,
            resource_id: report.subject_id,
            metadata: %{category: report.category}
          })
          |> Repo.insert()

        _ = %{report_id: report.id} |> AgentSocial.Safety.AlertWorker.new() |> Oban.insert()

        {:ok, report}

      error ->
        error
    end
  end
end
