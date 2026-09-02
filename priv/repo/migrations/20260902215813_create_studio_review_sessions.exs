defmodule AgentSocial.Repo.Migrations.CreateStudioReviewSessions do
  use Ecto.Migration

  def change do
    create table(:studio_review_sessions, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :human_id, references(:humans, type: :uuid, on_delete: :delete_all), null: false

      add :agent_binding_id, references(:agent_bindings, type: :uuid, on_delete: :delete_all),
        null: false

      add :token_digest, :binary, null: false
      add :draft, :map, null: false
      add :draft_version, :integer, null: false, default: 1
      add :review, :map, null: false, default: %{}
      add :status, :string, null: false, default: "review"

      add :published_content_id,
          references(:content_envelopes, type: :uuid, on_delete: :nilify_all)

      add :expires_at, :utc_datetime_usec, null: false
      add :last_agent_action_at, :utc_datetime_usec, null: false
      add :last_human_action_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:studio_review_sessions, [:token_digest])
    create index(:studio_review_sessions, [:human_id, :updated_at])
    create index(:studio_review_sessions, [:expires_at])

    create constraint(:studio_review_sessions, :studio_review_sessions_positive_version,
             check: "draft_version > 0"
           )

    create constraint(:studio_review_sessions, :studio_review_sessions_valid_status,
             check: "status IN ('review', 'published')"
           )
  end
end
