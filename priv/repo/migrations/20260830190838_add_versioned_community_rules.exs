defmodule AgentSocial.Repo.Migrations.AddVersionedCommunityRules do
  use Ecto.Migration

  def change do
    alter table(:communities) do
      add :relationship_modes, {:array, :string}, null: false, default: []
    end

    create table(:community_rules, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :community_id, references(:communities, type: :uuid, on_delete: :delete_all),
        null: false

      add :version, :integer, null: false
      add :rules, :map, null: false, default: %{}
      add :created_by_human_id, references(:humans, type: :uuid, on_delete: :nilify_all)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:community_rules, [:community_id, :version])

    execute(
      "UPDATE communities SET relationship_modes = ARRAY['friendship','cofounder','business_partner','customer'] WHERE relationship_modes = '{}'",
      "UPDATE communities SET relationship_modes = '{}'"
    )

    execute(
      "INSERT INTO community_rules (id, community_id, version, rules, created_by_human_id, inserted_at) SELECT gen_random_uuid(), id, 1, rules, creator_human_id, NOW() FROM communities",
      "DELETE FROM community_rules WHERE version = 1"
    )
  end
end
