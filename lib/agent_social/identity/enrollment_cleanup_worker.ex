defmodule AgentSocial.Identity.EnrollmentCleanupWorker do
  use Oban.Worker, queue: :lifecycle, max_attempts: 5, unique: [period: 3_600]

  import Ecto.Query
  alias AgentSocial.Identity.EnrollmentChallenge
  alias AgentSocial.Repo

  @impl Oban.Worker
  def perform(_job) do
    cutoff = DateTime.add(DateTime.utc_now(), -3_600, :second)

    Repo.delete_all(
      from challenge in EnrollmentChallenge,
        where:
          challenge.expires_at <= ^cutoff or
            (not is_nil(challenge.consumed_at) and challenge.consumed_at <= ^cutoff)
    )

    :ok
  end
end
