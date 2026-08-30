defmodule AgentSocial.Repo.Migrations.EnforceConsentPolicyFloor do
  use Ecto.Migration

  def change do
    alter table(:policies) do
      add :confirmation_requirements, :map, null: false, default: %{}
    end

    execute(
      "UPDATE policies SET require_intro_approval = TRUE, require_contact_approval = TRUE",
      "SELECT 1"
    )

    create constraint(:policies, :introduction_human_consent_required,
             check: "require_intro_approval = TRUE"
           )

    create constraint(:policies, :contact_human_consent_required,
             check: "require_contact_approval = TRUE"
           )
  end
end
