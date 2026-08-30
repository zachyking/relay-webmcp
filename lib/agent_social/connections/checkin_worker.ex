defmodule AgentSocial.Connections.CheckinWorker do
  @moduledoc "Emits the due 30/90-day connection check-in into the represented human's inbox."

  use Oban.Worker,
    queue: :lifecycle,
    max_attempts: 10,
    unique: [period: :infinity, fields: [:args]]

  alias AgentSocial.Connections.{Connection, ConnectionCheckin}
  alias AgentSocial.Operations.InboxEvent
  alias AgentSocial.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"checkin_id" => checkin_id}}) do
    case Repo.get(ConnectionCheckin, checkin_id) do
      nil ->
        :ok

      %ConnectionCheckin{responded_at: responded_at} when not is_nil(responded_at) ->
        :ok

      %ConnectionCheckin{} = checkin ->
        if DateTime.compare(checkin.due_at, DateTime.utc_now()) == :gt do
          {:snooze, max(DateTime.diff(checkin.due_at, DateTime.utc_now(), :second), 1)}
        else
          deliver_if_active(checkin)
        end
    end
  end

  defp deliver_if_active(checkin) do
    case Repo.get(Connection, checkin.connection_id) do
      %Connection{status: "active"} ->
        %InboxEvent{}
        |> InboxEvent.changeset(%{
          human_id: checkin.human_id,
          type: "connection.checkin_due",
          resource_type: "connection_checkin",
          resource_id: checkin.id,
          metadata: %{period_days: checkin.period_days, connection_id: checkin.connection_id}
        })
        |> Repo.insert()

        :ok

      _ ->
        :ok
    end
  end
end
