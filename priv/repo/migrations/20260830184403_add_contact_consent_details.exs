defmodule AgentSocial.Repo.Migrations.AddContactConsentDetails do
  use Ecto.Migration

  def change do
    alter table(:human_approvals) do
      add :purpose, :text
      add :grant_expires_at, :utc_datetime_usec
    end

    alter table(:contact_grants) do
      add :purpose, :text
    end
  end
end
