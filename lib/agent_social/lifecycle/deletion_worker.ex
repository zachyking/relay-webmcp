defmodule AgentSocial.Lifecycle.DeletionWorker do
  use Oban.Worker,
    queue: :lifecycle,
    max_attempts: 20,
    unique: [period: :infinity, fields: [:args]]

  alias AgentSocial.Identity.Human
  alias AgentSocial.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"human_id" => human_id}}) do
    case Repo.get(Human, human_id) do
      nil ->
        :ok

      %Human{status: "deleting", purge_after: purge_after} = human ->
        if DateTime.compare(purge_after, DateTime.utc_now()) in [:lt, :eq] do
          Repo.delete(human)
          :ok
        else
          {:snooze, max(DateTime.diff(purge_after, DateTime.utc_now(), :second), 60)}
        end

      _ ->
        {:discard, :deletion_cancelled}
    end
  end
end
