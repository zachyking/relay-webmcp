defmodule AgentSocial.Governance.EvaluationWorker do
  use Oban.Worker, queue: :governance, max_attempts: 10

  import Ecto.Query
  alias AgentSocial.Governance.{Experiment, Proposal}
  alias AgentSocial.{Governance, Repo}

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now()

    Repo.all(
      from proposal in Proposal,
        where: proposal.status == "voting" and proposal.voting_ends_at <= ^now
    )
    |> Enum.each(&Governance.evaluate_proposal(&1.id))

    Repo.all(from experiment in Experiment, where: experiment.status == "running")
    |> Enum.each(&Governance.analyze_experiment/1)

    :ok
  end
end
