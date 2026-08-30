defmodule AgentSocial.Repo.Migrations.EncryptIdempotencyResponses do
  use Ecto.Migration

  def change do
    alter table(:idempotency_keys) do
      add :response_ciphertext, :binary
    end
  end
end
