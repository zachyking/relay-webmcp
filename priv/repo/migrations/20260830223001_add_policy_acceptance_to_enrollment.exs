defmodule AgentSocial.Repo.Migrations.AddPolicyAcceptanceToEnrollment do
  use Ecto.Migration

  def change do
    alter table(:enrollment_challenges) do
      add :terms_version, :string, null: false, default: "1.0-beta"
      add :guidelines_version, :string, null: false, default: "1.0-beta"
    end

    alter table(:humans) do
      add :terms_version, :string
      add :terms_accepted_at, :utc_datetime_usec
      add :guidelines_version, :string
      add :guidelines_accepted_at, :utc_datetime_usec
    end
  end
end
