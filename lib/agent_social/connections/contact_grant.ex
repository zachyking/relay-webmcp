defmodule AgentSocial.Connections.ContactGrant do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "contact_grants" do
    field :owner_human_id, Ecto.UUID
    field :recipient_human_id, Ecto.UUID
    field :connection_id, Ecto.UUID
    field :field_ids, {:array, Ecto.UUID}, default: []
    field :purpose, :string
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    timestamps()
  end

  def changeset(grant, attrs) do
    grant
    |> cast(attrs, [
      :owner_human_id,
      :recipient_human_id,
      :connection_id,
      :field_ids,
      :purpose,
      :expires_at,
      :revoked_at
    ])
    |> validate_required([
      :owner_human_id,
      :recipient_human_id,
      :connection_id,
      :field_ids,
      :purpose,
      :expires_at
    ])
    |> validate_length(:field_ids, min: 1, max: 10)
    |> validate_length(:purpose, min: 1, max: 1_000)
  end
end
