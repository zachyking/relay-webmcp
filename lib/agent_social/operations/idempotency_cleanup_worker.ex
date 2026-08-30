defmodule AgentSocial.Operations.IdempotencyCleanupWorker do
  use Oban.Worker, queue: :default, max_attempts: 3, unique: [period: 3_600]

  @impl Oban.Worker
  def perform(_job), do: AgentSocial.Idempotency.purge_expired()
end
