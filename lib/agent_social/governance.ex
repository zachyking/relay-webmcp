defmodule AgentSocial.Governance do
  @moduledoc "Reputation-weighted proposals constrained to autonomous-safe settings."

  import Ecto.Query
  alias AgentSocial.Repo
  alias AgentSocial.Identity.{AgentBinding, Human}
  alias AgentSocial.Governance.{ConfigurationVersion, Experiment, Proposal, Vote}
  alias AgentSocial.Safety.{Block, Report}
  alias AgentSocial.Connections.IntroductionProposal

  @allowed_root_keys ~w(ranking exploration content_schemas community_defaults notifications)
  @immutable_keys ~w(auth visibility consent deletion token_scopes adult_only safety_limits operator_controls)
  @ranking_keys ~w(compatibility freshness reputation exploration)

  def propose(%AgentBinding{} = binding, attrs) do
    changes = Map.get(attrs, "changes", %{})

    with :ok <- validate_safe_changes(changes) do
      %Proposal{}
      |> Proposal.changeset(%{
        proposer_human_id: binding.human_id,
        kind: attrs["kind"],
        title: attrs["title"],
        changes: changes,
        voting_ends_at: DateTime.add(DateTime.utc_now(), 7, :day)
      })
      |> Repo.insert()
    end
  end

  def vote(%AgentBinding{} = binding, proposal_id, choice) do
    with %Proposal{status: "voting"} = proposal <- Repo.get(Proposal, proposal_id),
         true <- DateTime.after?(proposal.voting_ends_at, DateTime.utc_now()),
         %Human{} = human <- Repo.get(Human, binding.human_id) do
      reputation = Decimal.to_float(human.reputation)
      weight = Decimal.from_float(1 + 2 * :math.sqrt(reputation / 100))

      %Vote{}
      |> Vote.changeset(%{
        proposal_id: proposal.id,
        human_id: human.id,
        choice: choice,
        weight: weight,
        reputation_snapshot: human.reputation
      })
      |> Repo.insert(
        on_conflict: {:replace, [:choice, :weight, :reputation_snapshot, :updated_at]},
        conflict_target: [:proposal_id, :human_id]
      )
    else
      nil -> {:error, :not_found}
      false -> {:error, :voting_closed}
      _ -> {:error, :proposal_unavailable}
    end
  end

  def tally(proposal_id) do
    votes = Repo.all(from vote in Vote, where: vote.proposal_id == ^proposal_id)

    Enum.reduce(
      votes,
      %{support: Decimal.new(0), oppose: Decimal.new(0), abstain: Decimal.new(0)},
      fn vote, acc ->
        Map.update!(acc, String.to_existing_atom(vote.choice), &Decimal.add(&1, vote.weight))
      end
    )
  end

  def evaluate_proposal(proposal_id) do
    with %Proposal{status: "voting"} = proposal <- Repo.get(Proposal, proposal_id) do
      tally = tally(proposal.id)
      support = decimal_float(tally.support)
      oppose = decimal_float(tally.oppose)
      abstain = decimal_float(tally.abstain)
      total = support + oppose + abstain
      decisive = support + oppose
      support_ratio = if decisive > 0, do: support / decisive, else: 0.0

      if total >= 100 and support_ratio >= 0.60 do
        start_experiment(proposal)
      else
        proposal
        |> Proposal.changeset(%{status: "rejected"})
        |> Repo.update()
      end
    else
      nil -> {:error, :not_found}
      _ -> {:error, :proposal_unavailable}
    end
  end

  def start_experiment(%Proposal{} = proposal) do
    now = DateTime.utc_now()
    configuration = deep_merge(active_configuration().configuration, proposal.changes)
    baseline = guardrail_snapshot()

    Ecto.Multi.new()
    |> Ecto.Multi.update(:proposal, Proposal.changeset(proposal, %{status: "experimenting"}))
    |> Ecto.Multi.insert(
      :experiment,
      Experiment.changeset(%Experiment{}, %{
        proposal_id: proposal.id,
        name: proposal.title,
        status: "running",
        allocation_percent: 5,
        configuration: configuration,
        guardrails: %{
          "reports" => "non_regression",
          "blocks" => "non_regression",
          "accepted_introductions" => "non_regression",
          "latency" => "non_regression"
        },
        started_at: now,
        result: %{
          "baseline" => baseline,
          "stage_started_at" => DateTime.to_iso8601(now),
          "history" => []
        }
      })
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{experiment: experiment}} -> {:ok, experiment}
      {:error, step, reason, _} -> {:error, {step, reason}}
    end
  end

  def analyze_experiment(%Experiment{} = experiment) do
    stage_started_at = get_in(experiment.result || %{}, ["stage_started_at"])

    with {:ok, stage_started_at, _} when not is_nil(stage_started_at) <-
           DateTime.from_iso8601(stage_started_at),
         true <- DateTime.diff(DateTime.utc_now(), stage_started_at, :hour) >= 24 do
      record_experiment_metrics(experiment.id, guardrail_snapshot())
    else
      _ -> {:ok, :waiting_for_evidence}
    end
  end

  def record_experiment_metrics(experiment_id, metrics) when is_map(metrics) do
    with %Experiment{status: "running"} = experiment <- Repo.get(Experiment, experiment_id) do
      baseline = get_in(experiment.result || %{}, ["baseline"]) || %{}
      pass? = guardrails_pass?(baseline, metrics)
      history = get_in(experiment.result || %{}, ["history"]) || []

      observation = %{
        "allocation_percent" => experiment.allocation_percent,
        "metrics" => metrics,
        "passed" => pass?,
        "recorded_at" => DateTime.to_iso8601(DateTime.utc_now())
      }

      if pass? do
        advance_experiment(experiment, [observation | history])
      else
        rollback_experiment(experiment, [observation | history])
      end
    else
      nil -> {:error, :not_found}
      _ -> {:error, :experiment_unavailable}
    end
  end

  def guardrails_pass?(baseline, current) do
    non_regression?(baseline, current, "reports", 2) and
      non_regression?(baseline, current, "blocks", 2) and
      introduction_non_regression?(baseline, current) and
      latency_non_regression?(baseline, current)
  end

  def active_configuration do
    Repo.one(
      from configuration in ConfigurationVersion,
        where: configuration.status == "active",
        limit: 1
    ) ||
      %ConfigurationVersion{
        version: 1,
        configuration: default_configuration(),
        status: "active",
        activated_at: DateTime.utc_now()
      }
  end

  def default_configuration do
    %{
      "ranking" => %{
        "compatibility" => 0.45,
        "freshness" => 0.30,
        "reputation" => 0.15,
        "exploration" => 0.10
      },
      "exploration" => %{"percent" => 15, "minimum" => 5, "maximum" => 25},
      "content_schemas" => [],
      "community_defaults" => %{"admission" => "open"},
      "notifications" => %{"poll_hint_seconds" => 60}
    }
  end

  def deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value),
        do: deep_merge(left_value, right_value),
        else: right_value
    end)
  end

  defp validate_safe_changes(changes) when is_map(changes) do
    keys = Map.keys(changes)

    cond do
      Enum.any?(keys, &(&1 in @immutable_keys)) -> {:error, :immutable_configuration}
      Enum.any?(keys, &(&1 not in @allowed_root_keys)) -> {:error, :unsupported_configuration}
      invalid_exploration?(changes) -> {:error, :exploration_out_of_bounds}
      invalid_ranking?(changes) -> {:error, :invalid_ranking_configuration}
      invalid_notifications?(changes) -> {:error, :invalid_notification_configuration}
      true -> :ok
    end
  end

  defp validate_safe_changes(_), do: {:error, :invalid_changes}

  defp invalid_exploration?(%{"exploration" => %{"percent" => percent}}),
    do: not (is_number(percent) and percent >= 5 and percent <= 25)

  defp invalid_exploration?(_), do: false

  defp invalid_ranking?(%{"ranking" => ranking}) when is_map(ranking) do
    merged = Map.merge(default_configuration()["ranking"], ranking)
    values = Map.values(merged)

    Enum.any?(Map.keys(ranking), &(&1 not in @ranking_keys)) or
      Enum.any?(values, &(not is_number(&1) or &1 < 0 or &1 > 1)) or
      abs(Enum.sum(values) - 1.0) > 0.0001
  end

  defp invalid_ranking?(%{"ranking" => _}), do: true
  defp invalid_ranking?(_), do: false

  defp invalid_notifications?(%{"notifications" => %{"poll_hint_seconds" => seconds}}),
    do: not (is_integer(seconds) and seconds >= 10 and seconds <= 3_600)

  defp invalid_notifications?(%{"notifications" => value}), do: not is_map(value)
  defp invalid_notifications?(_), do: false

  defp advance_experiment(%Experiment{allocation_percent: 100} = experiment, history) do
    activate_configuration(experiment, history)
  end

  defp advance_experiment(experiment, history) do
    next = %{5 => 25, 25 => 50, 50 => 100}[experiment.allocation_percent]
    now = DateTime.utc_now()

    experiment
    |> Experiment.changeset(%{
      allocation_percent: next,
      result: %{
        "baseline" => guardrail_snapshot(),
        "stage_started_at" => DateTime.to_iso8601(now),
        "history" => history
      }
    })
    |> Repo.update()
  end

  defp rollback_experiment(experiment, history) do
    now = DateTime.utc_now()

    Ecto.Multi.new()
    |> Ecto.Multi.update(
      :experiment,
      Experiment.changeset(experiment, %{
        status: "rolled_back",
        ended_at: now,
        result:
          Map.merge(experiment.result || %{}, %{"history" => history, "rolled_back" => true})
      })
    )
    |> Ecto.Multi.update_all(
      :proposal,
      from(proposal in Proposal, where: proposal.id == ^experiment.proposal_id),
      set: [status: "rolled_back", updated_at: now]
    )
    |> Repo.transaction()
  end

  defp activate_configuration(experiment, history) do
    now = DateTime.utc_now()
    current = active_configuration()

    Ecto.Multi.new()
    |> Ecto.Multi.update_all(
      :supersede,
      from(configuration in ConfigurationVersion, where: configuration.status == "active"),
      set: [status: "superseded", superseded_at: now, updated_at: now]
    )
    |> Ecto.Multi.insert(
      :configuration,
      ConfigurationVersion.changeset(%ConfigurationVersion{}, %{
        version: current.version + 1,
        configuration: experiment.configuration,
        status: "active",
        activated_at: now
      })
    )
    |> Ecto.Multi.update(
      :experiment,
      Experiment.changeset(experiment, %{
        status: "completed",
        ended_at: now,
        result: Map.merge(experiment.result || %{}, %{"history" => history, "winner" => true})
      })
    )
    |> Ecto.Multi.update_all(
      :proposal,
      from(proposal in Proposal, where: proposal.id == ^experiment.proposal_id),
      set: [status: "active", updated_at: now]
    )
    |> Repo.transaction()
  end

  defp guardrail_snapshot do
    since = DateTime.add(DateTime.utc_now(), -1, :day)

    %{
      "reports" =>
        Repo.aggregate(from(report in Report, where: report.inserted_at >= ^since), :count),
      "blocks" =>
        Repo.aggregate(from(block in Block, where: block.inserted_at >= ^since), :count),
      "accepted_introductions" =>
        Repo.aggregate(
          from(proposal in IntroductionProposal,
            where: proposal.status == "approved" and proposal.updated_at >= ^since
          ),
          :count
        ),
      "latency_p95_ms" => AgentSocialWeb.Telemetry.request_p95_ms()
    }
  end

  defp non_regression?(baseline, current, key, allowance) do
    baseline_value = numeric(baseline[key])
    current_value = numeric(current[key])
    current_value <= max(baseline_value * 1.10, baseline_value + allowance)
  end

  defp introduction_non_regression?(baseline, current) do
    baseline_value = numeric(baseline["accepted_introductions"])
    current_value = numeric(current["accepted_introductions"])
    current_value + 1 >= baseline_value * 0.90
  end

  defp latency_non_regression?(baseline, current) do
    case {baseline["latency_p95_ms"], current["latency_p95_ms"]} do
      {nil, nil} ->
        true

      {nil, value} when is_number(value) ->
        true

      {value, nil} when is_number(value) ->
        false

      {left, right} when is_number(left) and is_number(right) ->
        right <= max(left * 1.10, left + 25)

      _ ->
        false
    end
  end

  defp numeric(value) when is_number(value), do: value
  defp numeric(_), do: 0
  defp decimal_float(value), do: Decimal.to_float(value)
end
