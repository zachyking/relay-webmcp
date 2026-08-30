defmodule AgentSocial.Repo.Migrations.AddMutationAuditProvenance do
  use Ecto.Migration

  def change do
    alter table(:policies) do
      add :version, :integer, null: false, default: 1
    end

    alter table(:audit_events) do
      add :agent_key_version, :integer
      add :client_id, :string
      add :policy_version, :integer
      add :result_state, :map, null: false, default: %{}
    end
  end
end
