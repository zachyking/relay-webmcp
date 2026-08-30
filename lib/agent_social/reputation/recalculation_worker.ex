defmodule AgentSocial.Reputation.RecalculationWorker do
  use Oban.Worker,
    queue: :governance,
    max_attempts: 5,
    unique: [period: 60, fields: [:args]]

  import Ecto.Query
  alias AgentSocial.Identity.Human
  alias AgentSocial.{Repo, Reputation}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"human_id" => human_id}}) do
    case Reputation.recalculate(human_id) do
      {:ok, _snapshot} -> :ok
      {:error, :not_found} -> :ok
      error -> error
    end
  end

  def perform(_job) do
    Repo.all(from human in Human, where: human.status == "active", select: human.id)
    |> Enum.reduce_while(:ok, fn human_id, :ok ->
      case Reputation.recalculate(human_id) do
        {:ok, _snapshot} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  def enqueue(human_id) do
    %{human_id: human_id} |> new() |> Oban.insert()
  end
end
