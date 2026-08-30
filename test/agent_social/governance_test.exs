defmodule AgentSocial.GovernanceTest do
  use AgentSocial.DataCase

  alias AgentSocial.Governance

  test "immutable configuration is rejected and vote weight remains within one to three" do
    voter = actor()

    assert {:error, :immutable_configuration} =
             Governance.propose(voter.binding, %{
               "kind" => "ranking",
               "title" => "Remove the approval requirement",
               "changes" => %{"consent" => %{"required" => false}}
             })

    assert {:ok, proposal} =
             Governance.propose(voter.binding, %{
               "kind" => "ranking",
               "title" => "Tune exploration safely",
               "changes" => %{"exploration" => %{"percent" => 20}}
             })

    assert {:ok, vote} = Governance.vote(voter.binding, proposal.id, "support")
    weight = Decimal.to_float(vote.weight)
    assert weight >= 1.0 and weight <= 3.0
  end

  test "ranking weights must remain bounded and normalized" do
    proposer = actor()

    assert {:error, :invalid_ranking_configuration} =
             Governance.propose(proposer.binding, %{
               "kind" => "ranking",
               "title" => "Overweight freshness",
               "changes" => %{"ranking" => %{"freshness" => 0.9}}
             })

    assert {:ok, _proposal} =
             Governance.propose(proposer.binding, %{
               "kind" => "ranking",
               "title" => "Balanced ranking update",
               "changes" => %{
                 "ranking" => %{
                   "compatibility" => 0.4,
                   "freshness" => 0.3,
                   "reputation" => 0.2,
                   "exploration" => 0.1
                 }
               }
             })
  end

  test "a passing experiment advances 5, 25, 50, 100 and activates a version" do
    proposer = actor()

    {:ok, proposal} =
      Governance.propose(proposer.binding, %{
        "kind" => "ranking",
        "title" => "Increase controlled exploration",
        "changes" => %{"exploration" => %{"percent" => 20}}
      })

    assert {:ok, experiment} = Governance.start_experiment(proposal)
    assert experiment.allocation_percent == 5

    experiment = pass_stage(experiment)
    assert experiment.allocation_percent == 25
    experiment = pass_stage(experiment)
    assert experiment.allocation_percent == 50
    experiment = pass_stage(experiment)
    assert experiment.allocation_percent == 100

    assert {:ok, result} =
             Governance.record_experiment_metrics(
               experiment.id,
               experiment.result["baseline"]
             )

    assert result.experiment.status == "completed"
    assert Governance.active_configuration().version == 2

    assert get_in(Governance.active_configuration().configuration, ["exploration", "percent"]) ==
             20
  end

  test "a guardrail regression rolls an experiment back" do
    proposer = actor()

    {:ok, proposal} =
      Governance.propose(proposer.binding, %{
        "kind" => "notification",
        "title" => "Change polling frequency",
        "changes" => %{"notifications" => %{"poll_hint_seconds" => 90}}
      })

    {:ok, experiment} = Governance.start_experiment(proposal)
    baseline = experiment.result["baseline"]
    regression = Map.put(baseline, "reports", baseline["reports"] + 100)

    assert {:ok, result} = Governance.record_experiment_metrics(experiment.id, regression)
    assert result.experiment.status == "rolled_back"
  end

  defp pass_stage(experiment) do
    assert {:ok, advanced} =
             Governance.record_experiment_metrics(
               experiment.id,
               experiment.result["baseline"]
             )

    advanced
  end
end
