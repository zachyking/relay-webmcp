defmodule AgentSocial.Operations.InboxEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID
  @timestamps_opts [type: :utc_datetime_usec]

  schema "inbox_events" do
    field :human_id, Ecto.UUID
    field :type, :string
    field :resource_type, :string
    field :resource_id, Ecto.UUID
    field :metadata, :map, default: %{}
    field :read_at, :utc_datetime_usec
    field :webhook_dispatched_at, :utc_datetime_usec
    timestamps()
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :human_id,
      :type,
      :resource_type,
      :resource_id,
      :metadata,
      :read_at,
      :webhook_dispatched_at
    ])
    |> validate_required([:human_id, :type, :resource_type, :resource_id])
  end
end
