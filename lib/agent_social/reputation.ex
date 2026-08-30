defmodule AgentSocial.Reputation do
  @moduledoc "Recalculates the human-owned, agent-independent 0–100 reputation score."

  import Ecto.Query
  alias Ecto.Multi
  alias AgentSocial.Connections.{ConnectionCheckin, IntroductionProposal}
  alias AgentSocial.Identity.Human
  alias AgentSocial.Reputation.Snapshot
  alias AgentSocial.{Repo, Safety}

  @weights %{
    retained_connections: 0.40,
    introduction_quality: 0.20,
    community_trust: 0.15,
    reliable_participation: 0.10,
    safety_history: 0.15
  }

  def recalculate(human_id) do
    with %Human{} = human <- Repo.get(Human, human_id) do
      components = components(human_id)
      score = score(components)
      decimal_score = Decimal.from_float(Float.round(score, 2))
      now = DateTime.utc_now()

      Multi.new()
      |> Multi.update(:human, Ecto.Changeset.change(human, reputation: decimal_score))
      |> Multi.insert(
        :snapshot,
        Snapshot.changeset(%Snapshot{}, %{
          human_id: human_id,
          score: decimal_score,
          components: stringify_components(components),
          calculated_at: now
        })
      )
      |> Repo.transaction()
      |> case do
        {:ok, %{snapshot: snapshot}} -> {:ok, snapshot}
        {:error, step, reason, _} -> {:error, {step, reason}}
      end
    else
      nil -> {:error, :not_found}
    end
  end

  def components(human_id) do
    checkins = Repo.all(from c in ConnectionCheckin, where: c.human_id == ^human_id)
    responded = Enum.filter(checkins, &(not is_nil(&1.responded_at)))
    retained = Enum.filter(responded, &(&1.active == true and &1.useful == true))

    introductions =
      Repo.all(from p in IntroductionProposal, where: p.proposer_human_id == ^human_id)

    resolved_introductions = Enum.filter(introductions, &(&1.status in ["approved", "declined"]))
    approved_introductions = Enum.count(resolved_introductions, &(&1.status == "approved"))

    due_checkins =
      Enum.filter(checkins, &(DateTime.compare(&1.due_at, DateTime.utc_now()) in [:lt, :eq]))

    moderation_count =
      Repo.aggregate(
        from(action in "moderation_actions",
          where:
            field(action, :subject_type) == "human" and
              field(action, :subject_id) == type(^human_id, Ecto.UUID) and
              is_nil(field(action, :reversed_at))
        ),
        :count
      )

    report_count =
      Repo.aggregate(
        from(report in Safety.Report,
          where: report.subject_type == "human" and report.subject_id == ^human_id
        ),
        :count
      )

    blocked_count =
      Repo.aggregate(
        from(block in Safety.Block, where: block.blocked_human_id == ^human_id),
        :count
      )

    %{
      retained_connections: ratio_score(length(retained), length(responded), 50.0),
      introduction_quality:
        ratio_score(approved_introductions, length(resolved_introductions), 50.0),
      community_trust: max(100.0 - moderation_count * 15.0, 0.0),
      reliable_participation:
        ratio_score(
          Enum.count(due_checkins, &(not is_nil(&1.responded_at))),
          length(due_checkins),
          50.0
        ),
      safety_history: max(100.0 - report_count * 15.0 - blocked_count * 5.0, 0.0),
      signal_count:
        length(responded) + length(resolved_introductions) + moderation_count + report_count +
          blocked_count
    }
  end

  def score(%{signal_count: 0}), do: 20.0

  def score(components) do
    @weights
    |> Enum.reduce(0.0, fn {component, weight}, total ->
      total + Map.fetch!(components, component) * weight
    end)
    |> min(100.0)
    |> max(0.0)
  end

  defp ratio_score(_, 0, default), do: default
  defp ratio_score(numerator, denominator, _default), do: numerator / denominator * 100.0

  defp stringify_components(components) do
    Map.new(components, fn {key, value} -> {Atom.to_string(key), value} end)
  end
end
