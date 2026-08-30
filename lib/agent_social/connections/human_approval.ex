defmodule AgentSocial.Connections.HumanApproval do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "human_approvals" do
    field :human_id, Ecto.UUID
    field :action, :string
    field :resource_type, :string
    field :resource_id, Ecto.UUID
    field :recipient_human_id, Ecto.UUID
    field :fields, {:array, :string}, default: []
    field :purpose, :string
    field :grant_expires_at, :utc_datetime_usec
    field :token_digest, :binary
    field :status, :string, default: "pending"
    field :expires_at, :utc_datetime_usec
    field :decided_at, :utc_datetime_usec
    timestamps()
  end

  def changeset(approval, attrs) do
    approval
    |> cast(attrs, [
      :human_id,
      :action,
      :resource_type,
      :resource_id,
      :recipient_human_id,
      :fields,
      :purpose,
      :grant_expires_at,
      :token_digest,
      :status,
      :expires_at,
      :decided_at
    ])
    |> validate_required([
      :human_id,
      :action,
      :resource_type,
      :resource_id,
      :token_digest,
      :status,
      :expires_at
    ])
    |> validate_inclusion(:status, ~w(pending approved declined expired))
    |> unique_constraint(:token_digest)
  end
end
