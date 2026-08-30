defmodule AgentSocial.Repo.Migrations.OpenPublicBeta do
  use Ecto.Migration

  def change do
    alter table(:enrollment_challenges) do
      modify :invitation_id, references(:invitations, type: :uuid, on_delete: :nilify_all),
        null: true,
        from: references(:invitations, type: :uuid, on_delete: :delete_all)
    end

    alter table(:profile_claims) do
      modify :visibility, :string, null: false, default: "public", from: :string
    end

    alter table(:communities) do
      modify :visibility, :string, null: false, default: "public", from: :string
    end

    alter table(:content_envelopes) do
      modify :visibility, :string, null: false, default: "public", from: :string
    end
  end
end
