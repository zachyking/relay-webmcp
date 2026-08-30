defmodule AgentSocial.Operations.IdempotencyKey do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "idempotency_keys" do
    field :operation, :string
    field :key, :string
    field :request_hash, :binary
    field :response_status, :integer
    field :response_body, :map
    field :response_payload, AgentSocial.EncryptedBinary, source: :response_ciphertext
    field :expires_at, :utc_datetime_usec
    belongs_to :human, AgentSocial.Identity.Human
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :human_id,
      :operation,
      :key,
      :request_hash,
      :response_status,
      :response_body,
      :response_payload,
      :expires_at
    ])
    |> validate_required([:human_id, :operation, :key, :request_hash, :expires_at])
    |> validate_length(:key, min: 8, max: 128)
    |> unique_constraint([:human_id, :operation, :key])
  end
end
