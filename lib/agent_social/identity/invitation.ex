defmodule AgentSocial.Identity.Invitation do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID
  @timestamps_opts [type: :utc_datetime_usec]

  schema "invitations" do
    field :code_digest, :binary
    field :created_by_id, Ecto.UUID
    field :max_uses, :integer, default: 1
    field :use_count, :integer, default: 0
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    timestamps()
  end

  def changeset(invitation, attrs) do
    invitation
    |> cast(attrs, [:code_digest, :created_by_id, :max_uses, :expires_at])
    |> validate_required([:code_digest, :max_uses, :expires_at])
    |> validate_number(:max_uses, greater_than: 0)
    |> unique_constraint(:code_digest)
  end
end
