defmodule AgentSocial.Repo.Migrations.AddInboxWebhookDispatch do
  use Ecto.Migration

  def change do
    alter table(:inbox_events) do
      add :webhook_dispatched_at, :utc_datetime_usec
    end

    create index(:inbox_events, [:webhook_dispatched_at], where: "webhook_dispatched_at IS NULL")
  end
end
